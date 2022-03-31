// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./iface.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";


contract RockXStaking is Initializable, PausableUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address payable;
    using Address for address;

    // stored credentials
    struct ValidatorCredential {
        bytes pubkey;
        bytes signature;
    }
    
    // track ether debts to return to async caller
    struct Debt {
        address account;
        uint256 amount;
    }

    /**
        Incorrect storage preservation:

        |Implementation_v0   |Implementation_v1        |
        |--------------------|-------------------------|
        |address _owner      |address _lastContributor | <=== Storage collision!
        |mapping _balances   |address _owner           |
        |uint256 _supply     |mapping _balances        |
        |...                 |uint256 _supply          |
        |                    |...                      |
        Correct storage preservation:

        |Implementation_v0   |Implementation_v1        |
        |--------------------|-------------------------|
        |address _owner      |address _owner           |
        |mapping _balances   |mapping _balances        |
        |uint256 _supply     |uint256 _supply          |
        |...                 |address _lastContributor | <=== Storage extension.
        |                    |...                      |
    */

    // Always extend storage instead of modifying it
    // Variables in implementation v0 
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 internal constant DEPOSIT_SIZE = 32 ether;
    uint256 internal constant MULTIPLIER = 1e18; 
    uint256 internal constant DEPOSIT_AMOUNT_UNIT = 1000000000 wei;
    uint256 internal constant SIGNATURE_LENGTH = 96;
    uint256 internal constant PUBKEY_LENGTH = 48;

    address public ethDepositContract;  // ETH 2.0 Deposit contract
    address public xETHAddress;         // xETH token address

    uint256 public managerFeeMilli = 100;   // manger's fee in 1/1000
    bytes32 public withdrawalCredentials;   // WithdrawCredential for all validator
    
    // credentials, pushed by owner
    ValidatorCredential [] private validatorRegistry;

    // next validator id
    uint256 private nextValidatorId;

    // track user staking
    uint256 public totalStaked;             // track total staked ethers for validators, rounded to 32 ethers
    uint256 public totalDeposited;          // track total deposited ethers from users
    uint256 public totalWithdrawed;         // track total withdrawed ethers

    // track revenue from validators to form exchange ratio
    uint256 public accountedUserRevenue;    // accounted shared user revenue
    uint256 public accountedManagerRevenue; // accounted manager's revenue

    // track beacon validator & balance
    uint256 public beaconValidatorSnapshot;
    uint256 public beaconBalanceSnapshot;

    // track stopped validators
    uint256 public stoppedBalance;          // the balance snapshot of those stopped validators
    uint256 private lastStopTimestamp;      // record timestamp of last stop
    uint256 [] private stoppedValidators;   // track stopped validator ID

    // FIFO of debts from redeemFromValidators
    mapping(uint256=>Debt) private etherDebts;
    uint256 private firstDebt = 1;
    uint256 private lastDebt = 0;

    // phase switch from 0 to 1
    uint256 private phase = 0;

    /** 
     * ======================================================================================
     * 
     * SYSTEM SETTINGS, OPERATED VIA OWNER(DAO/TIMELOCK)
     * 
     * ======================================================================================
     */

    /**
     * @dev receive revenue
     */
    receive() external payable {
        emit RewardReceived(msg.value);
    }

    /**
     * @dev only phase
     */
    modifier onlyPhase(uint256 requiredPhase) {
        require(requiredPhase >= phase, "PHASE_MISMATCH");
        _;
    }

    /**
     * @dev pause the contract
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev unpause the contract
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev initialization address
     */
    function initialize() initializer public {
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    /**
     * @dev phase switch
     */
    function switchPhase(uint256 newPhase) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require (newPhase >= phase, "PHASE_ROLLBACK");
        phase = newPhase;
    }

    /**
     * @dev register a validator
     */
    function registerValidator(bytes calldata pubkey, bytes calldata signature) external onlyRole(OPERATOR_ROLE) {
        require(signature.length == SIGNATURE_LENGTH, "INCONSISTENT_SIG_LEN");
        require(pubkey.length == PUBKEY_LENGTH, "INCONSISTENT_PUBKEY_LEN");
        validatorRegistry.push(ValidatorCredential({pubkey:pubkey, signature:signature}));
    }

    /**
     * @dev replace a validator in case of msitakes
     */
    function replaceValidator(uint256 index, bytes calldata pubkey, bytes calldata signature) external onlyRole(OPERATOR_ROLE) {
        require(index < validatorRegistry.length, "OUT_OF_RANGE");
        require(index < nextValidatorId, "ALREADY_ACTIVATED");
        require(signature.length == SIGNATURE_LENGTH, "INCONSISTENT_SIG_LEN");
        validatorRegistry[index] = ValidatorCredential({pubkey:pubkey, signature:signature});
    }

    /**
     * @dev register a batch of validators
     */
    function registerValidators(bytes [] calldata pubkeys, bytes [] calldata signatures) external onlyRole(OPERATOR_ROLE) {
        require(pubkeys.length == signatures.length, "LENGTH_NOT_EQUAL");
        uint256 n = pubkeys.length;
        for(uint256 i=0;i<n;i++) {
            validatorRegistry.push(ValidatorCredential({pubkey:pubkeys[i], signature:signatures[i]}));
        }
    }
    
    /**
     * @dev set manager's fee in 1/1000
     */
    function setManagerFeeMilli(uint256 milli) external onlyRole(DEFAULT_ADMIN_ROLE)  {
        require(milli >=0 && milli <=1000, "OUT_OF_RANGE");
        managerFeeMilli = milli;

        emit ManagerFeeSet(milli);
    }

    /**
     * @dev set eth deposit contract address
     */
    function setETHDepositContract(address _ethDepositContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ethDepositContract = _ethDepositContract;
    }

    /**
     @dev set withdraw credential to receive revenue, usually this should be the contract itself.
     */
    function setWithdrawCredential(bytes32 withdrawalCredentials_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        withdrawalCredentials = withdrawalCredentials_;
        emit WithdrawCredentialSet(withdrawalCredentials);
    } 

    /**
     * @dev manager withdraw fees
     */
    function withdrawManagerFee(uint256 amount, address to) external nonReentrant onlyRole(MANAGER_ROLE)  {
        require(accountedManagerRevenue >= amount, "INSUFFICIENT_MANAGER_FEE");
        require(_checkEthersBalance(amount), "INSUFFICIENT_ETHERS");
        accountedManagerRevenue -= amount;
        payable(to).sendValue(amount);
    }

    /**
     * @dev report validators count and total balance
     */
    function pushBeacon(uint256 _beaconValidators, uint256 _beaconBalance, uint256 ts) external onlyRole(ORACLE_ROLE) {
        require(_beaconValidators <= nextValidatorId, "REPORTED_MORE_DEPOSITED");
        require(_beaconValidators + stoppedValidators.length >= beaconValidatorSnapshot, "REPORTED_LESS_VALIDATORS");
        require(block.timestamp >= ts, "REPORTED_CLOCK_DRIFT");
        require(ts > lastStopTimestamp, "REPORTED_EXPIRED_TIMESTAMP");

        uint256 rewardBase = beaconBalanceSnapshot;
        if (_beaconValidators + stoppedValidators.length > beaconValidatorSnapshot) {         
            // newly appeared validators
            uint256 diff = _beaconValidators + stoppedValidators.length - beaconValidatorSnapshot;
            rewardBase += diff * DEPOSIT_SIZE;
        }

        // take snapshot of current balances & validators,including stopped ones
        beaconBalanceSnapshot = _beaconBalance + stoppedBalance; 
        beaconValidatorSnapshot = _beaconValidators + stoppedValidators.length;

        // the actual increase in balance is the reward
        if (beaconBalanceSnapshot > rewardBase) {
            uint256 rewards = beaconBalanceSnapshot - rewardBase;
            _distributeRewards(rewards);
        }
    }

    /**
     * @dev operator stops validator and return ethers staked along with revenue
     * the revenue will stored in this contract
     */
    function validatorStopped(uint256 [] calldata stoppedIDs) external payable nonReentrant onlyRole(OPERATOR_ROLE) {
        require(stoppedIDs.length > 0, "NO_ID_GIVEN");
        // guarantee sufficient ethers returned
        require(msg.value >= stoppedIDs.length * DEPOSIT_SIZE, "RETURNED_LESS_ETHERS");

        // ethers to pay
        uint256 ethersPayable = stoppedIDs.length * DEPOSIT_SIZE;
        for (uint i=firstDebt;i<=lastDebt;i++) {
            if (ethersPayable == 0) {
                break;
            }

            Debt storage debt = etherDebts[i];

            // clean debts
            uint256 toPay = debt.amount <= ethersPayable? debt.amount:ethersPayable;
            debt.amount -= toPay;
            ethersPayable -= toPay;
            payable(debt.account).sendValue(toPay);

            // log
            emit DebtPaid(debt.account, debt.amount);

            // untrack 
            if (debt.amount == 0) {
                _dequeueDebt();
            }
        }

        // record stopped validators snapshot.
        for (uint i=0;i<stoppedIDs.length;i++) {
            stoppedValidators.push(stoppedIDs[i]);
        }
        stoppedBalance += msg.value;

        // record timestamp
        lastStopTimestamp = block.timestamp;
    }

    /**
     * ======================================================================================
     * 
     * VIEW FUNCTIONS
     * 
     * ======================================================================================
     */

    /**
     * @dev return number of registered validator
     */
    function getRegisteredValidatorsCount() external view returns (uint256) {
        return validatorRegistry.length;
    }
    
    /**
     * @dev return n-th of validator credential
     */
    function getRegisteredValidator(uint256 id) external view 
        returns (bytes memory pubkey, bytes memory signature) {
        return(validatorRegistry[id].pubkey, validatorRegistry[id].signature);
    }

    /**
     * @dev return next validator id
     */
    function getNextValidatorId() external view returns (uint256) {
        return nextValidatorId;
    }

    /**
     * @dev return exchange ratio of xETH:ETH, multiplied by 1e18
     */
    function exchangeRatio() external view returns (uint256) {
        uint256 xETHAmount = IERC20(xETHAddress).totalSupply();
        uint256 ratio = _currentEthers() * MULTIPLIER / xETHAmount;
        return ratio;
    }

    /**
     * @dev check ethers withdrawble without stopping validators.
     */
    function getEthersRedeemable() internal view returns(uint256) {
        uint256 pendingEthers = totalDeposited - totalStaked;
        return address(this).balance - pendingEthers;
    }

    /**
     * @dev return debt of index
     */
    function checkDebt(uint256 index) external view returns (address account, uint256 amount) {
        Debt memory debt = etherDebts[index];
        return (debt.account, debt.amount);
    }
    /**
     * @dev return debt queue index
     */
    function getDebtQueue() external view returns (uint256 first, uint256 last) {
        return (firstDebt, lastDebt);
    }

    /**
     * @dev get stopped validators count
     */
    function getStoppedValidatorsCount() external view returns (uint256) {
        return stoppedValidators.length;
    }
    
    /**
     * @dev get stopped validators ID range
     */
    function getStoppedValidators(uint256 idx_from, uint256 idx_to) external view returns (uint256[] memory) {
        uint[] memory result = new uint[](idx_to - idx_from);
        uint counter = 0;
        for (uint i = idx_from; i <= idx_to;i++) {
            result[counter] = stoppedValidators[i];
            counter++;
        }
        return result;
    }

     /**
     * ======================================================================================
     * 
     * EXTERNAL FUNCTIONS
     * 
     * ======================================================================================
     */
    /**
     * @dev mint xETH with ETH
     */
    function mint() external payable nonReentrant whenNotPaused {
        // only from EOA
        require(!msg.sender.isContract() && msg.sender == tx.origin);
        require(msg.value > 0, "MINT_ZERO");

        // mint xETH while keep the exchange ratio invariant
        //
        // current_ethers = totalDeposited + accountedUserRevenue - totalWithdrawed
        // amount XETH to mint = xETH * (msg.value/current_ethers)
        //
        uint256 amountXETH = IERC20(xETHAddress).totalSupply();
        uint256 currentEthers = _currentEthers();
        uint256 toMint = msg.value;  // default exchange ratio 1:1
        if (currentEthers > 0) { // avert division overflow
            toMint = amountXETH * msg.value / currentEthers;
       }
        
        // sum total deposited ethers
        totalDeposited += msg.value;
        uint256 numValidators = (totalDeposited - totalStaked) / DEPOSIT_SIZE;

        // spin up n nodes
        for (uint256 i = 0;i<numValidators;i++) {
            _spinup();
        }

        // mint xETH
        IMintableContract(xETHAddress).mint(msg.sender, toMint);
    }

    /**
     * @dev redeem N * 32Ethers, which will turn off validadators,
     * note this function is asynchronous, the caller will only receive his ethers
     * after the validator has turned off.
     *
     * this function is dedicated for institutional operations.
     * 
     * redeem keeps the ratio invariant
     */
    function redeemFromValidators(uint256 ethersToRedeem) external nonReentrant onlyPhase(1) {
        // only from EOA
        require(!msg.sender.isContract() && msg.sender == tx.origin);
        require(ethersToRedeem % DEPOSIT_SIZE == 0, "REDEEM_NOT_IN_32ETHERS");

        uint256 totalXETH = IERC20(xETHAddress).totalSupply();
        uint256 xETHToBurn = totalXETH * ethersToRedeem / _currentEthers();
        
        // transfer xETH from sender & burn
        IERC20(xETHAddress).safeTransferFrom(msg.sender, address(this), xETHToBurn);
        IMintableContract(xETHAddress).burn(xETHToBurn);

        // track ether debts
        _enqueueDebt(msg.sender, ethersToRedeem);

        // log 
        emit RedeemFromValidator(xETHToBurn, ethersToRedeem);
    }

    /**
     * @dev redeem ETH by burning xETH with current exchange ratio, 
     * approve xETH to this contract first.
     *
     * amount xETH to burn:
     *      xETH * ethers_to_redeem/current_ethers
     *
     * redeem keeps the ratio invariant
     */
    function redeemUnderlying(uint256 ethersToRedeem) external nonReentrant {
        // only from EOA
        require(!msg.sender.isContract() && msg.sender == tx.origin);
        require(_checkEthersBalance(ethersToRedeem), "INSUFFICIENT_ETHERS");

        uint256 totalXETH = IERC20(xETHAddress).totalSupply();
        uint256 xETHToBurn = totalXETH * ethersToRedeem / _currentEthers();
        
        // transfer xETH from sender & burn
        IERC20(xETHAddress).safeTransferFrom(msg.sender, address(this), xETHToBurn);
        IMintableContract(xETHAddress).burn(xETHToBurn);

        // send ethers back to sender
        payable(msg.sender).sendValue(ethersToRedeem);
        totalWithdrawed += ethersToRedeem;

        // emit amount withdrawed
        emit Redeemed(xETHToBurn, ethersToRedeem);
    }

    /**
     * @dev redeem ETH by burning xETH with current exchange ratio, 
     * approve xETH to this contract first.
     * 
     * amount ethers to return:
     *  current_ethers * xETHToBurn/ xETH
     *
     * redeem keeps the ratio invariant
     */
    function redeem(uint256 xETHToBurn) external nonReentrant {
        // only from EOA
        require(!msg.sender.isContract() && msg.sender == tx.origin);
         
        uint256 totalXETH = IERC20(xETHAddress).totalSupply();
        uint256 ethersToRedeem = _currentEthers() * xETHToBurn / totalXETH;
        require(_checkEthersBalance(ethersToRedeem), "INSUFFICIENT_ETHERS");

        // transfer xETH from sender & burn
        IERC20(xETHAddress).safeTransferFrom(msg.sender, address(this), xETHToBurn);
        IMintableContract(xETHAddress).burn(xETHToBurn);

        // send ethers back to sender
        payable(msg.sender).sendValue(ethersToRedeem);
        totalWithdrawed += ethersToRedeem;

        // emit amount withdrawed
        emit Redeemed(xETHToBurn, ethersToRedeem);
    }

    /** 
     * ======================================================================================
     * 
     * INTERNAL FUNCTIONS
     * 
     * ======================================================================================
     */
    function _enqueueDebt(address account, uint256 amount) internal {
        lastDebt += 1;
        etherDebts[lastDebt] = Debt({account:account, amount:amount});
    }

    function _dequeueDebt() internal returns (Debt memory debt) {
        require(lastDebt >= firstDebt);  // non-empty queue
        debt = etherDebts[firstDebt];
        delete etherDebts[firstDebt];
        firstDebt += 1;
    }

    /**
     * @dev distribute revenue
     */
    function _distributeRewards(uint256 rewards) internal {
        // rewards distribution
        uint256 fee = rewards * managerFeeMilli / 1000;
        accountedManagerRevenue += fee;
        accountedUserRevenue += rewards - fee;
        emit RevenueAccounted(rewards);
    }

    /**
     * @dev returns totalDeposited + accountedUserRevenue - totalWithdrawed
     */
    function _currentEthers() internal view returns(uint256) {
        return totalDeposited + accountedUserRevenue - totalWithdrawed;
    }

    /**
     * @dev check ethers withdrawble
     */
    function _checkEthersBalance(uint256 amount) internal view returns(bool) {
        uint256 pendingEthers = totalDeposited - totalStaked;
        if (address(this).balance - pendingEthers >= amount) {
            return true;
        }
        return false;
    }

    /**
     * @dev spin up the node
     */
    function _spinup() internal {
        // emit a log
        emit ValidatorActivated(nextValidatorId);

        // deposit to ethereum contract
        require(nextValidatorId < validatorRegistry.length) ;

         // load credential
        ValidatorCredential memory cred = validatorRegistry[nextValidatorId];
        _stake(cred.pubkey, cred.signature);

        totalStaked += DEPOSIT_SIZE;
        nextValidatorId++;        
    }

    /**
    * @dev Invokes a deposit call to the official Deposit contract
    */
    function _stake(bytes memory _pubkey, bytes memory _signature) internal {
        require(withdrawalCredentials != bytes32(0x0), "WITHDRAWAL_CREDENTIALS_NOT_SET");
         // The following computations and Merkle tree-ization will make official Deposit contract happy
        uint256 value = DEPOSIT_SIZE;
        uint256 depositAmount = value / DEPOSIT_AMOUNT_UNIT;
        assert(depositAmount * DEPOSIT_AMOUNT_UNIT == value);    // properly rounded

        // Compute deposit data root (`DepositData` hash tree root) according to deposit_contract.sol
        bytes32 pubkeyRoot = sha256(_pad64(_pubkey));
        bytes32 signatureRoot = sha256(
            abi.encodePacked(
                sha256(BytesLib.slice(_signature, 0, 64)),
                sha256(_pad64(BytesLib.slice(_signature, 64, SIGNATURE_LENGTH - 64)))
            )
        );
        bytes32 depositDataRoot = sha256(
            abi.encodePacked(
                sha256(abi.encodePacked(pubkeyRoot, withdrawalCredentials)),
                sha256(abi.encodePacked(_toLittleEndian64(depositAmount), signatureRoot))
            )
        );
        

        IDepositContract(ethDepositContract).deposit{value:DEPOSIT_SIZE} (
            _pubkey, abi.encodePacked(withdrawalCredentials), _signature, depositDataRoot);

    }

    /**
      * @dev Padding memory array with zeroes up to 64 bytes on the right
      * @param _b Memory array of size 32 .. 64
      */
    function _pad64(bytes memory _b) internal pure returns (bytes memory) {
        assert(_b.length >= 32 && _b.length <= 64);
        if (64 == _b.length)
            return _b;

        bytes memory zero32 = new bytes(32);
        assembly { mstore(add(zero32, 0x20), 0) }

        if (32 == _b.length)
            return BytesLib.concat(_b, zero32);
        else
            return BytesLib.concat(_b, BytesLib.slice(zero32, 0, uint256(64) - _b.length));
    }

    /**
      * @dev Converting value to little endian bytes and padding up to 32 bytes on the right
      * @param _value Number less than `2**64` for compatibility reasons
      */
    function _toLittleEndian64(uint256 _value) internal pure returns (uint256 result) {
        result = 0;
        uint256 temp_value = _value;
        for (uint256 i = 0; i < 8; ++i) {
            result = (result << 8) | (temp_value & 0xFF);
            temp_value >>= 8;
        }

        assert(0 == temp_value);    // fully converted
        result <<= (24 * 8);
    }

    /**
     * ======================================================================================
     * 
     * ROCKX SYSTEM EVENTS
     *
     * ======================================================================================
     */
    event ValidatorActivated(uint256 node_id);
    event RevenueAccounted(uint256 amount);
    event RewardReceived(uint256 amount);
    event ManagerAccountSet(address account);
    event ManagerFeeSet(uint256 milli);
    event Redeemed(uint256 amountXETH, uint256 amountETH);
    event RedeemFromValidator(uint256 amountXETH, uint256 amountETH);
    event WithdrawCredentialSet(bytes32 withdrawCredential);
    event DebtPaid(address creditor, uint256 amountEther);
}
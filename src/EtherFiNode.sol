// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IEtherFiNode.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./eigenlayer-interfaces/IEigenPodManager.sol";
import "./eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";
import "./eigenlayer-interfaces/IDelegationManager.sol";
import "forge-std/console.sol";

contract EtherFiNode is IEtherFiNode, IERC1271 {
    address public etherFiNodesManager;

    uint256 public DEPRECATED_localRevenueIndex;
    uint256 public DEPRECATED_vestedAuctionRewards;
    string public DEPRECATED_ipfsHashForEncryptedValidatorKey;
    uint32 public DEPRECATED_exitRequestTimestamp;
    uint32 public DEPRECATED_exitTimestamp;
    uint32 public DEPRECATED_stakingStartTimestamp;
    VALIDATOR_PHASE public DEPRECATED_phase;

    uint32 public DEPRECATED_restakingObservedExitBlock;
    address public eigenPod;

    /// @dev Is this withdrawal safe is configured for restaking within the etherfi protocol.
    bool public isRestakingEnabled;

    uint16 public version;
    uint16 private _numAssociatedValidators; // num validators in {LIVE, BEING_SLASHED, EXITED} phase
    uint16 public numExitRequestsByTnft;
    uint16 public numExitedValidators; // EXITED & but not FULLY_WITHDRAWN

    mapping(uint256 => uint256) public associatedValidatorIndices;
    uint256[] public associatedValidatorIds; // validators in {STAKE_DEPOSITED, WAITING_FOR_APPROVAL, LIVE, BEING_SLASHED, EXITED} phase

    // Track the amount of pending/completed withdrawals;
    uint64 public pendingWithdrawalFromRestakingInGwei; // incremented when the delayed withdrawal (from EigenPod to EtherFiNode) is queued, decremented when it is completed
    uint64 public completedWithdrawalFromRestakingInGwei; // incremented when the delayed withdarwal is completed, decremented when the fund is withdrawan (from EtherFiNode to the externals via fullWithdraw call)

    // eigenLayer phase 1 bookeeping
    // we need to mark a block from which we know all beaconchain eth has been moved to the eigenPod
    // so that we can properly calculate exit payouts and ensure queued withdrawals have been resolved
    // (eigenLayer withdrawals are tied to blocknumber instead of timestamp)
    mapping(uint256 => uint32) restakingObservedExitBlocks;

    error ForwardedCallNotAllowed();
    error CallFailed(bytes data);

    event EigenPodCreated(address indexed nodeAddress, address indexed podAddress);

    //--------------------------------------------------------------------------------------
    //----------------------------------  CONSTRUCTOR   ------------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        etherFiNodesManager = address(0x000000000000000000000000000000000000dEaD); // prevent initialization of the proxy implementation
    }

    /// @notice Based on the sources where they come from, the staking rewards are split into
    ///  - those from the execution layer: transaction fees and MEV
    ///  - those from the consensus layer: staking rewards for attesting the state of the chain, 
    ///    proposing a new block, or being selected in a validator sync committee
    ///  To receive the rewards from the execution layer, it should have 'receive()' function.
    receive() external payable {}

    /// @dev called once immediately after creating a new instance of a EtheriNode beacon proxy
    function initialize(address _etherFiNodesManager) external {
        require(DEPRECATED_phase == VALIDATOR_PHASE.NOT_INITIALIZED, "ALREADY_INITIALIZED");
        require(etherFiNodesManager == address(0), "ALREADY_INITIALIZED");
        require(_etherFiNodesManager != address(0), "NO_ZERO_ADDRESS");
        etherFiNodesManager = _etherFiNodesManager;
        version = 1;
    }

    // Update the safe contract from verison 0 to version 1
    // if `_validatorId` != 0, the v0 safe contract currently is tied to the validator with its id = `_validatorId`
    // this function updates it to v1 so that it can be used by multiple validators 
    // else `_validatorId` == 0, this safe is not tied to any validator yet
    function migrateVersion(uint256 _validatorId, IEtherFiNodesManager.ValidatorInfo memory _info) external onlyEtherFiNodeManagerContract {
        if (version != 0) return;
        
        DEPRECATED_exitRequestTimestamp = 0;
        DEPRECATED_exitTimestamp = 0;
        DEPRECATED_stakingStartTimestamp = 0;
        DEPRECATED_phase = VALIDATOR_PHASE.NOT_INITIALIZED;
        delete DEPRECATED_ipfsHashForEncryptedValidatorKey;

        version = 1;

        if (_validatorId != 0) {
            require(_numAssociatedValidators == 0, "ALREADY_INITIALIZED");
            registerValidator(_validatorId, false);

            updateNumberOfAssociatedValidators(1, 0);

            // Meaning that the validator got `sendExitRequest` before the safe version 1 release
            // EFM._updateExitRequestTimestamp (which updates 'numExitRequestsByTnft') was not called. So, process that here
            if (_info.exitRequestTimestamp > 0) {
                updateNumExitRequests(1, 0);
            }

            // Meaning that the validator got `processNodeExit` before the safe version 1 release
            // EFM._setValidatorPhase (which updates 'numExitedValidators') was not called. So, process that here
            if (_info.exitTimestamp > 0) {
                updateNumExitedValidators(1, 0);
            }
        }
    }

    // At version 0, an EtherFiNode contract is associated with only one validator
    // After version 1, it can be associated with multiple validators having the same (B-nft, T-nft, node operator) 
    // returns the number of the validators in {LIVE, BEING_SLASHED, EXITED} phase associated with this safe
    function numAssociatedValidators() public view returns (uint256) {
        if (version == 0) {
            // For the safe at version 0, `phase` variable is still valid and can be used to check if the validator is still active 
            if (DEPRECATED_phase == VALIDATOR_PHASE.LIVE || DEPRECATED_phase == VALIDATOR_PHASE.BEING_SLASHED || DEPRECATED_phase == VALIDATOR_PHASE.EXITED) {
                return 1;
            } else {
                return 0;
            }
        } else {
            return _numAssociatedValidators;
        }
    }

    function registerValidator(uint256 _validatorId, bool _enableRestaking) public onlyEtherFiNodeManagerContract ensureLatestVersion {
        require(numAssociatedValidators() == 0 || isRestakingEnabled == _enableRestaking, "restaking status mismatch");

        {
            uint256 index = associatedValidatorIds.length;
            associatedValidatorIds.push(_validatorId);
            associatedValidatorIndices[_validatorId] = index;
        }

        if (_enableRestaking) {
            isRestakingEnabled = true;
            createEigenPod(); // NOOP if already exists
        }
    }

    /// @dev deRegister the validator from the safe
    ///      if there is no more validator associated with this safe, it is recycled to be used again in the withdrawal safe pool
    function unRegisterValidator(
        uint256 _validatorId,
        IEtherFiNodesManager.ValidatorInfo memory _info
    ) external onlyEtherFiNodeManagerContract ensureLatestVersion returns (bool) {        
        require(_info.phase == VALIDATOR_PHASE.FULLY_WITHDRAWN || _info.phase == VALIDATOR_PHASE.NOT_INITIALIZED, "invalid phase");

        // If the phase changed from EXITED to FULLY_WITHDRAWN, decrement the counter
        if (_info.phase == VALIDATOR_PHASE.FULLY_WITHDRAWN) {
            numExitedValidators -= 1;
        }

        // If there was an exit request, decrement the number of exit requests
        if (_info.exitRequestTimestamp != 0) {
            numExitRequestsByTnft -= 1;
        }

        {
            uint256 index = associatedValidatorIndices[_validatorId];
            uint256 endIndex = associatedValidatorIds.length - 1;
            uint256 end = associatedValidatorIds[endIndex];

            associatedValidatorIds[index] = associatedValidatorIds[endIndex];
            associatedValidatorIndices[end] = index;
            
            associatedValidatorIds.pop();
            delete associatedValidatorIndices[_validatorId];
        }
        
        if (associatedValidatorIds.length == 0) {
            require(numAssociatedValidators() == 0, "INVALID_STATE");

            restakingObservedExitBlocks[_validatorId] = 0;
            isRestakingEnabled = false;
            return true;
        }
        return false;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    function updateNumberOfAssociatedValidators(uint16 _up, uint16 _down) public onlyEtherFiNodeManagerContract ensureLatestVersion {
        if (_up > 0) _numAssociatedValidators += _up;
        if (_down > 0) _numAssociatedValidators -= _down;
    }

    function updateNumExitRequests(uint16 _up, uint16 _down) public onlyEtherFiNodeManagerContract ensureLatestVersion {
        if (_up > 0) numExitRequestsByTnft += _up;
        if (_down > 0) numExitRequestsByTnft -= _down;
    }

    function updateNumExitedValidators(uint16 _up, uint16 _down) public onlyEtherFiNodeManagerContract ensureLatestVersion {
        if (_up > 0) numExitedValidators += _up;
        if (_down > 0) numExitedValidators -= _down;
    }

    /// @notice process the exit
    // TODO: make it permission-less call
    function processNodeExit(uint256 _validatorId) external onlyEtherFiNodeManagerContract ensureLatestVersion returns (bytes32[] memory fullWithdrawalRoots) {
        if (isRestakingEnabled) {
            // eigenLayer bookeeping
            // we need to mark a block from which we know all beaconchain eth has been moved to the eigenPod
            // so that we can properly calculate exit payouts and ensure queued withdrawals have been resolved
            // (eigenLayer withdrawals are tied to blocknumber instead of timestamp)
            restakingObservedExitBlocks[_validatorId] = uint32(block.number);

            fullWithdrawalRoots = _queueEigenpodFullWithdrawal();
            require(fullWithdrawalRoots.length == 1, "NO_FULLWITHDRAWAL_QUEUED");
        }
    }

    function processFullWithdraw(uint256 _validatorId) external onlyEtherFiNodeManagerContract ensureLatestVersion {
        updateNumberOfAssociatedValidators(0, 1);

        if (isRestakingEnabled) {
            // TODO: revisit for the case of slashing
            require(completedWithdrawalFromRestakingInGwei >= 32 ether / 1 gwei, "INSUFFICIENT_BALANCE");
            completedWithdrawalFromRestakingInGwei -= uint64(32 ether / 1 gwei);
        }
    }

    function completeQueuedWithdrawal(IDelegationManager.Withdrawal memory withdrawals, uint256 middlewareTimesIndexes, bool _receiveAsTokens) external onlyEtherFiNodeManagerContract {
        IDelegationManager.Withdrawal[] memory _withdrawals = new IDelegationManager.Withdrawal[](1);
        _withdrawals[0] = withdrawals;
        uint256[] memory _middlewareTimesIndexes = new uint256[](1);
        _middlewareTimesIndexes[0] = middlewareTimesIndexes;
        return _completeQueuedWithdrawals(_withdrawals, _middlewareTimesIndexes, _receiveAsTokens);
    }

    function completeQueuedWithdrawals(IDelegationManager.Withdrawal[] memory withdrawals, uint256[] memory middlewareTimesIndexes, bool _receiveAsTokens) external onlyEtherFiNodeManagerContract {
        return _completeQueuedWithdrawals(withdrawals, middlewareTimesIndexes, _receiveAsTokens);
    }

    // `DelegationManager.completeQueuedWithdrawals` is used to complete the withdrawals:
    // (1) by `EtherFiNode._queueRestakedFullWithdrawal`. It is used to process the full withdraw
    // (2) by `DelegationManager.undelegate`
    // While `_receiveAsTokens == True` for (1), `_receiveAsTokens == False` for (2)
    // (Note that this is a simplication based on the use cases)
    function _completeQueuedWithdrawals(IDelegationManager.Withdrawal[] memory withdrawals, uint256[] memory middlewareTimesIndexes, bool _receiveAsTokens) internal {
        uint256 totalAmount = 0;

        bool[] memory receiveAsTokens = new bool[](withdrawals.length);
        IERC20[][] memory tokens = new IERC20[][](withdrawals.length);
        for (uint256 i = 0; i < withdrawals.length; i++) {
            require(withdrawals[i].withdrawer == address(this) && withdrawals[i].staker == address(this), "INVALID");

            receiveAsTokens[i] = _receiveAsTokens;
            tokens[i] = new IERC20[](withdrawals[i].strategies.length);
            for (uint256 j = 0; j < withdrawals[i].shares.length; j++) {
                totalAmount += withdrawals[i].shares[j];
            }
        }

        if (_receiveAsTokens) {
            // the queued withdrawal is for (1) full withdraw, so the pendingWithdrawalFromRestakingInGwei should be at least 32 ether
            require(pendingWithdrawalFromRestakingInGwei >= uint64(totalAmount / 1 gwei), "NO_PENDING_WITHDRAWAL");
            pendingWithdrawalFromRestakingInGwei -= uint64(totalAmount / 1 gwei);
            completedWithdrawalFromRestakingInGwei += uint64(totalAmount / 1 gwei);
        } else {
            // the queued withdrawal is for (2) undelegate, we put a guard `pendingWithdrawalFromRestakingInGwei` == 0
            // If it is non-zero, that means there is at least one validator of which delayed withdrawal is in the queue.
            // Complete that first.
            /// @dev this is not the most optimal way to handle these two use cases, but we ack that it's a temporary solution
            require(pendingWithdrawalFromRestakingInGwei == 0, "PENDING_WITHDRAWAL_NOT_ZERO");
        }

        IDelegationManager mgr = IEtherFiNodesManager(etherFiNodesManager).delegationManager();
        mgr.completeQueuedWithdrawals(withdrawals, tokens, middlewareTimesIndexes, receiveAsTokens);
    }

    /// @dev transfer funds from the withdrawal safe to the 4 associated parties (bNFT, tNFT, treasury, nodeOperator)
    function withdrawFunds(
        address _treasury, uint256 _treasuryAmount,
        address _operator, uint256 _operatorAmount,
        address _tnftHolder, uint256 _tnftAmount,
        address _bnftHolder, uint256 _bnftAmount
    ) external onlyEtherFiNodeManagerContract ensureLatestVersion {
        // the recipients of the funds must be able to receive the fund
        // if it is a smart contract, they should implement either receive() or fallback() properly
        // It's designed to prevent malicious actors from pausing the withdrawals
        bool sent;
        if (_operatorAmount > 0) {
            (sent, ) = payable(_operator).call{value: _operatorAmount, gas: 10000}("");
            _treasuryAmount += (!sent) ? _operatorAmount : 0;
        }
        if (_bnftAmount > 0) {
            (sent, ) = payable(_bnftHolder).call{value: _bnftAmount, gas: 12000}("");
            _treasuryAmount += (!sent) ? _bnftAmount : 0;
        }
        if (_tnftAmount > 0) {
            (sent, ) = payable(_tnftHolder).call{value: _tnftAmount, gas: 12000}("");
            _treasuryAmount += (!sent) ? _tnftAmount : 0;
        }
        if (_treasuryAmount > 0) {
            (sent, ) = _treasury.call{value: _treasuryAmount, gas: 2300}("");
            require(sent, "ETH_SEND_FAILED");
        }
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------------  GETTER  --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Fetch the staking rewards accrued in the safe that can be paid out to (toNodeOperator, toTnft, toBnft, toTreasury)
    /// @param _splits the splits for the staking rewards
    ///
    /// @return toNodeOperator  the payout to the Node Operator
    /// @return toTnft          the payout to the T-NFT holder
    /// @return toBnft          the payout to the B-NFT holder
    /// @return toTreasury      the payout to the Treasury
    function getRewardsPayouts(
        uint32 _exitRequestTimestamp,
        IEtherFiNodesManager.RewardsSplit memory _splits
    ) public view returns (uint256, uint256, uint256, uint256) {
        uint256 _balance = withdrawableBalanceInExecutionLayer();
        return _calculateSplits(_balance, _splits);
    }

    /// @notice Compute the non exit penalty for the b-nft holder
    /// @param _tNftExitRequestTimestamp the timestamp when the T-NFT holder asked the B-NFT holder to exit the node
    /// @param _bNftExitRequestTimestamp the timestamp when the B-NFT holder submitted the exit request to the beacon network
    function getNonExitPenalty(
        uint32 _tNftExitRequestTimestamp, 
        uint32 _bNftExitRequestTimestamp
    ) public view returns (uint256) {
        if (_tNftExitRequestTimestamp == 0) return 0;

        uint128 _penaltyPrinciple = IEtherFiNodesManager(etherFiNodesManager).nonExitPenaltyPrincipal();
        uint64 _dailyPenalty = IEtherFiNodesManager(etherFiNodesManager).nonExitPenaltyDailyRate();
        uint256 daysElapsed = _getDaysPassedSince(_tNftExitRequestTimestamp, _bNftExitRequestTimestamp);
        if (daysElapsed > 365) {
            return _penaltyPrinciple;
        }

        uint256 remaining = _penaltyPrinciple;
        while (daysElapsed > 0) {
            uint256 exponent = Math.min(7, daysElapsed);
            remaining = (remaining * (10000 - uint256(_dailyPenalty)) ** exponent) / (10000 ** exponent);
            daysElapsed -= Math.min(7, daysElapsed);
        }

        return _penaltyPrinciple - remaining;
    }

    /// @notice total balance (in the execution layer) of this withdrawal safe split into its component parts.
    ///   1. the withdrawal safe balance
    ///   2. the EigenPod balance
    ///   3. the withdrawals pending in DelayedWithdrawalRouter
    function splitBalanceInExecutionLayer() public view returns (uint256 _withdrawalSafe, uint256 _eigenPod, uint256 _delayedWithdrawalRouter) {
        _withdrawalSafe = address(this).balance;

        if (isRestakingEnabled) {
            _eigenPod = eigenPod.balance;

            IDelayedWithdrawalRouter delayedWithdrawalRouter = IDelayedWithdrawalRouter(IEtherFiNodesManager(etherFiNodesManager).DEPRECATED_delayedWithdrawalRouter());
            IDelayedWithdrawalRouter.DelayedWithdrawal[] memory delayedWithdrawals = delayedWithdrawalRouter.getUserDelayedWithdrawals(address(this));
            for (uint256 x = 0; x < delayedWithdrawals.length; x++) {
                _delayedWithdrawalRouter += delayedWithdrawals[x].amount;
            }
        }
        return (_withdrawalSafe, _eigenPod, _delayedWithdrawalRouter);
    }


    /// @notice total balance (wei) of this safe currently in the execution layer.
    function totalBalanceInExecutionLayer() public view returns (uint256) {
        (uint256 _safe, uint256 _pod, uint256 _router) = splitBalanceInExecutionLayer();
        return _safe + _pod + _router;
    }

    /// @notice balance (wei) of this safe that could be immediately withdrawn.
    ///         This only differs from the balance in the safe in the case of restaked validators
    ///         because some funds might not be withdrawable yet due to eigenlayer's queued withdrawal system
    function withdrawableBalanceInExecutionLayer() public view returns (uint256) {
        uint256 safeBalance = address(this).balance;
        uint256 claimableBalance = 0;
        if (isRestakingEnabled) {
            IDelayedWithdrawalRouter delayedWithdrawalRouter = IDelayedWithdrawalRouter(IEtherFiNodesManager(etherFiNodesManager).DEPRECATED_delayedWithdrawalRouter());
            IDelayedWithdrawalRouter.DelayedWithdrawal[] memory claimableWithdrawals = delayedWithdrawalRouter.getClaimableUserDelayedWithdrawals(address(this));
            for (uint256 x = 0; x < claimableWithdrawals.length; x++) {
                claimableBalance += claimableWithdrawals[x].amount;
            }
        }
        return safeBalance + claimableBalance;
    }

    function moveFundsToManager(uint256 _amount) external onlyEtherFiNodeManagerContract {
        (bool sent, ) = etherFiNodesManager.call{value: _amount, gas: 6000}("");
        require(sent, "ETH_SEND_FAILED");
    }

    function getFullWithdrawalPayouts(
        IEtherFiNodesManager.ValidatorInfo memory _info,
        IEtherFiNodesManager.RewardsSplit memory _SRsplits
    ) public view onlyEtherFiNodeManagerContract returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) {
        if (version == 0 || numAssociatedValidators() == 1) {
            return calculateTVL(0, _info, _SRsplits, true);
        } else if (version == 1) {
            // If (version ==1 && numAssociatedValidators() > 1)
            //  the full withdrwal for a validator only considers its principal amount (= 16 ether ~ 32 ether)
            //  the staking rewards remain in the safe contract
            // Therefore, if a validator is slashed, the accrued staking rewards are used to cover the slashing amount
            // In the upcoming version, the proof system will be ported so that the penalty amount properly considered for withdrawals

            uint256[] memory payouts = new uint256[](4); // (toNodeOperator, toTnft, toBnft, toTreasury)
            uint256 principal = (withdrawableBalanceInExecutionLayer() >= 32 ether) ? 32 ether : withdrawableBalanceInExecutionLayer();
            (payouts[2], payouts[1]) = _calculatePrincipals(principal);
            (payouts[0], payouts[1], payouts[2], payouts[3]) = _applyNonExitPenalty(_info, payouts[0], payouts[1], payouts[2], payouts[3]);

            return (payouts[0], payouts[1], payouts[2], payouts[3]);
        } else {
            require(false, "WRONG_VERSION");
        }
    }

    /// @notice Given the current (phase, beacon balance) of a validator, compute the TVLs for {node operator, t-nft holder, b-nft holder, treasury}
    function getTvlSplits(
        VALIDATOR_PHASE _phase, 
        uint256 _beaconBalance,
        bool _onlyWithdrawable
    ) internal view returns (uint256 stakingRewards, uint256 principal) {
        uint256 numValidators = numAssociatedValidators();
        if (numValidators == 0) return (0, 0);

        // Consider the total balance of the safe in the execution layer
        uint256 balance = _onlyWithdrawable? withdrawableBalanceInExecutionLayer() : totalBalanceInExecutionLayer();

        // Calculate the total principal for the exited validators. 
        // It must be in the range of [16 ether * numExitedValidators, 32 ether * numExitedValidators]
        // since the maximum slashing amount is 16 ether per validator (without considering the slashing from restaking)
        // 
        // Here, the accrued rewards in the safe are used to cover the loss from the slashing
        // For example, say the safe had 1 ether accrued staking rewards, but the validator got slashed till 16 ether
        // After exiting the validator, the safe balance becomes 17 ether (16 ether from the slashed validator, 1 ether was the accrued rewards),
        // the accrued rewards are used to cover the slashing amount, thus, being considered as principal.
        // While this is not the best way to handle it, we acknowledge it as a temporary solution until the more advanced & efficient method is implemented
        require (balance >= 16 ether * numExitedValidators, "INSUFFICIENT_BALANCE");
        uint256 totalPrincipalForExitedValidators = 16 ether * numExitedValidators + Math.min(balance - 16 ether * numExitedValidators, 16 ether * numExitedValidators);

        // The rewards in the safe are split equally among the associated validators
        // The rewards in the beacon are considered as the staking rewards of the current validator being considered
        uint256 stakingRewardsInEL = (balance - totalPrincipalForExitedValidators) / numValidators;
        uint256 stakingRewardsInBeacon = (_beaconBalance > 32 ether ? _beaconBalance - 32 ether : 0);
        stakingRewards = stakingRewardsInEL + stakingRewardsInBeacon;

        // The principal amount is computed
        if (_phase == VALIDATOR_PHASE.EXITED) {
            principal = totalPrincipalForExitedValidators / numExitedValidators;
            require(_beaconBalance == 0, "Exited validator must have zero balanace in the beacon");
        } else if (_phase == VALIDATOR_PHASE.LIVE || _phase == VALIDATOR_PHASE.BEING_SLASHED) {
            principal = _beaconBalance - stakingRewardsInBeacon;
        } else {
            require(false, "INVALID_PHASE");
        }
        require(principal <= 32 ether && principal >= 16 ether, "INCORRECT_AMOUNT");
    }

    /// @notice Given
    ///         - the current balance of the validator in Consensus Layer (or Beacon)
    ///         - the current balance of the ether fi node contract,
    ///         Compute the TVLs for {node operator, t-nft holder, b-nft holder, treasury}
    /// @param _beaconBalance the balance of the validator in Consensus Layer
    /// @param _SRsplits the splits for the Staking Rewards
    ///
    /// @return toNodeOperator  the payout to the Node Operator
    /// @return toTnft          the payout to the T-NFT holder
    /// @return toBnft          the payout to the B-NFT holder
    /// @return toTreasury      the payout to the Treasury
    function calculateTVL(
        uint256 _beaconBalance,
        IEtherFiNodesManager.ValidatorInfo memory _info,
        IEtherFiNodesManager.RewardsSplit memory _SRsplits,
        bool _onlyWithdrawable
    ) public view onlyEtherFiNodeManagerContract returns (uint256, uint256, uint256, uint256) {
        (uint256 stakingRewards, uint256 principal) = getTvlSplits(_info.phase, _beaconBalance, _onlyWithdrawable);
        if (stakingRewards + principal == 0) return (0, 0, 0, 0);

        // Compute the payouts for the staking rewards
        uint256[] memory payouts = new uint256[](4); // (toNodeOperator, toTnft, toBnft, toTreasury)
        (payouts[0], payouts[1], payouts[2], payouts[3]) = _calculateSplits(stakingRewards, _SRsplits);

        // Compute the payouts for the principals to {B, T}-NFTs
        (uint256 toBnftPrincipal, uint256 toTnftPrincipal) = _calculatePrincipals(principal);
        payouts[1] += toTnftPrincipal;
        payouts[2] += toBnftPrincipal;

        // Apply the non-exit penalty to the B-NFT
        (payouts[0], payouts[1], payouts[2], payouts[3]) = _applyNonExitPenalty(_info, payouts[0], payouts[1], payouts[2], payouts[3]);

        require(payouts[0] + payouts[1] + payouts[2] + payouts[3] == stakingRewards + principal, "INCORRECT_AMOUNT");
        return (payouts[0], payouts[1], payouts[2], payouts[3]);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- CALL FORWARDING  ------------------------------------
    //--------------------------------------------------------------------------------------

    function callEigenPod(bytes calldata _data) external onlyEtherFiNodeManagerContract returns (bytes memory) {
        return Address.functionCall(eigenPod, _data);
    }

    function forwardCall(address _to, bytes calldata _data) external onlyEtherFiNodeManagerContract returns (bytes memory) {
        return Address.functionCall(_to, _data);
    }


    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------


    function _applyNonExitPenalty(
        IEtherFiNodesManager.ValidatorInfo memory _info, 
        uint256 _toNodeOperator, 
        uint256 _toTnft, 
        uint256 _toBnft, 
        uint256 _toTreasury
    ) internal view returns (uint256, uint256, uint256, uint256) {
        // NonExitPenalty grows till 1 ether
        uint256 bnftNonExitPenalty = getNonExitPenalty(_info.exitRequestTimestamp, _info.exitTimestamp);
        uint256 appliedPenalty = Math.min(_toBnft, bnftNonExitPenalty);
        uint256 incentiveToNoToExitValidator = Math.min(appliedPenalty, 0.2 ether);

        // Cap the incentive to the operator under 0.2 ether.
        // the rest (= penalty - incentive to NO) goes to the treasury
        _toNodeOperator += incentiveToNoToExitValidator;
        _toTreasury += appliedPenalty - incentiveToNoToExitValidator;
        _toBnft -= appliedPenalty;

        return (_toNodeOperator, _toTnft, _toBnft, _toTreasury);
    }

    /// @notice Calculates values for payouts based on certain parameters
    /// @param _totalAmount The total amount to split
    /// @param _splits The splits for the staking rewards
    ///
    /// @return toNodeOperator  the payout to the Node Operator
    /// @return toTnft          the payout to the T-NFT holder
    /// @return toBnft          the payout to the B-NFT holder
    /// @return toTreasury      the payout to the Treasury
    function _calculateSplits(
        uint256 _totalAmount,
        IEtherFiNodesManager.RewardsSplit memory _splits
    ) internal pure returns (uint256 toNodeOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury) {
        uint256 scale = _splits.treasury + _splits.nodeOperator + _splits.tnft + _splits.bnft;
        toNodeOperator = (_totalAmount * _splits.nodeOperator) / scale;
        toTnft = (_totalAmount * _splits.tnft) / scale;
        toBnft = (_totalAmount * _splits.bnft) / scale;
        toTreasury = _totalAmount - (toBnft + toTnft + toNodeOperator);
        return (toNodeOperator, toTnft, toBnft, toTreasury);
    }

    /// @notice Calculate the principal for the T-NFT and B-NFT holders based on the balance
    /// @param _balance The balance of the node
    /// @return toBnftPrincipal the principal for the B-NFT holder
    /// @return toTnftPrincipal the principal for the T-NFT holder
    function _calculatePrincipals(
        uint256 _balance
    ) internal pure returns (uint256 , uint256) {
        // Check if the ETH principal withdrawn (16 ETH ~ 32 ETH) from beacon is within this contract
        // If not:
        //  - case 1: ETH is still in the EigenPod contract. Need to get that out
        //  - case 2: ETH is withdrawn from the EigenPod contract, but ETH got slashed and the amount is under 16 ETH
        // Note that the case 2 won't happen until EigenLayer's AVS goes live on mainnet and the slashing mechanism is added
        // We will need upgrades again once EigenLayer's AVS goes live
        require(_balance >= 16 ether && _balance <= 32 ether, "INCORRECT_PRINCIPAL_AMOUNT");
        
        uint256 toBnftPrincipal = (_balance >= 31 ether) ? _balance - 30 ether : 1 ether;
        uint256 toTnftPrincipal = _balance - toBnftPrincipal;
        return (toBnftPrincipal, toTnftPrincipal);
    }

    function _getDaysPassedSince(
        uint32 _startTimestamp,
        uint32 _endTimestamp
    ) public pure returns (uint256) {
        uint256 timeElapsed = _endTimestamp - Math.min(_startTimestamp, _endTimestamp);
        return uint256(timeElapsed / (24 * 3_600));
    }

    /// @dev implementation address for beacon proxy.
    ///      https://docs.openzeppelin.com/contracts/3.x/api/proxy#beacon
    function implementation() external view returns (address) {
        bytes32 slot = bytes32(uint256(keccak256('eip1967.proxy.beacon')) - 1);
        address implementationVariable;
        assembly {
            implementationVariable := sload(slot)
        }

        IBeacon beacon = IBeacon(implementationVariable);
        return beacon.implementation();
    }


    //--------------------------------------------------------------------------------------
    //-----------------------------------  RESTAKING  --------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Start a PEPE pod checkpoint balance proof. A new proof cannot be started until
    ///         the previous proof is completed
    function startCheckpoint(bool _revertIfNoBalance) external onlyEtherFiNodeManagerContract {
        IEigenPod(eigenPod).startCheckpoint(_revertIfNoBalance);
    }

    // @notice you can delegate 1 additional wallet that is allowed to call startCheckpoint() and
    //         verifyWithdrawalCredentials() on behalf of this pod
    function setProofSubmitter(address _newProofSubmitter) external onlyEtherFiNodeManagerContract {
        IEigenPod(eigenPod).setProofSubmitter(_newProofSubmitter);
    }

    /// @notice create a new eigenPod associated with this withdrawal safe
    /// @dev to take advantage of restaking via eigenlayer the validator associated with this
    ///      withdrawal safe must set their withdrawalCredentials to point to this eigenPod
    ///      and not to the withdrawal safe itself
    function createEigenPod() public {
        if (eigenPod != address(0x0)) return; // already have pod
        IEigenPodManager eigenPodManager = IEigenPodManager(IEtherFiNodesManager(etherFiNodesManager).eigenPodManager());
        eigenPodManager.createPod();
        eigenPod = address(eigenPodManager.getPod(address(this)));
        emit EigenPodCreated(address(this), eigenPod);
    }

    // returns the withdrawal roots for the queued full-withdrawals
    // the {NonBeaconChainEthWithdrawal, partial withdraw}'s queued withdrawals can be retrieved (indexed) on DelayedWithdrawalRouter
    function queueEigenpodFullWithdrawal() public onlyEtherFiNodeManagerContract returns (bytes32[] memory fullWithdrawalRoots) {
        return _queueEigenpodFullWithdrawal();
    }

    function _queueEigenpodFullWithdrawal() private returns (bytes32[] memory fullWithdrawalRoots) {
        if (!isRestakingEnabled) return fullWithdrawalRoots;

        // Withdrawals from Eigenlayer are queued through either the DelayedWithdrawalRouter (DEPRECATED) or the DelegationManager.
        // pre-PEPE update, nonBeaconChainEth and partial withdrawals are queued through the DelayedWithdrawalRouter.
        // post-PEPE update, all withdrawals are queued through the DelegationManager

        // calculate the pending amount. The withdrawal proof verification will update the EigenPod's `withdrawableRestakedExecutionLayerGwei` value
        uint256 unclaimedFullWithdrawalAmountInGwei = IEigenPod(eigenPod).withdrawableRestakedExecutionLayerGwei() - pendingWithdrawalFromRestakingInGwei;
        if (unclaimedFullWithdrawalAmountInGwei == 0) return fullWithdrawalRoots;

        // TODO: revisit for the case of slashing
        // we will need to re-visit this logic once the EigenLayer's slashing mechanism is implemented
        // + we need to consider the slashing amount in the full withdrawal from the beacon layer as well
        require(unclaimedFullWithdrawalAmountInGwei >= 32 ether / 1 gwei, "SLASHED");

        // Update the pending withdrawal amount
        // Note that the call to `DelegationManager.queueWithdrawals(...)` won't update the EigenPod's `withdrawableRestakedExecutionLayerGwei`
        // It is updated only when the withdrawal is completed by the `DelegationManager.completeQueuedWithdrawals(...)`
        // That is why we use two variables for accounting
        pendingWithdrawalFromRestakingInGwei += uint64(32 ether / 1 gwei);

        IDelegationManager delegationManager = IEtherFiNodesManager(etherFiNodesManager).delegationManager();

        // Queue the withdrawal for whatever amount is available
        IDelegationManager.QueuedWithdrawalParams[] memory params = new IDelegationManager.QueuedWithdrawalParams[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);

        strategies[0] = delegationManager.beaconChainETHStrategy();
        shares[0] = 32 ether;
        params[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: shares,
            withdrawer: address(this)
        });

        // each withdrawal root is hash of the withdrawal object, "keccak256(abi.encode(withdrawal))"
        return delegationManager.queueWithdrawals(params);
    }

    /// @dev as of eigenlayer's PEPE upgrade the delayedWithdrawalRouter is deprecated.
    ///         once all outstanding funds have been claimed we can delete this functionality
    function DEPRECATED_claimDelayedWithdrawalRouterWithdrawals(uint256 _validatorId) public {
        if (!isRestakingEnabled) return;

        uint256 maxWithdrawals = 10; // maximum number of withdrawals to process in 1 tx

        // only claim if we have active unclaimed withdrawals
        IDelayedWithdrawalRouter delayedWithdrawalRouter = IDelayedWithdrawalRouter(IEtherFiNodesManager(etherFiNodesManager).DEPRECATED_delayedWithdrawalRouter());
        if (delayedWithdrawalRouter.getUserDelayedWithdrawals(address(this)).length > 0) {
            delayedWithdrawalRouter.claimDelayedWithdrawals(address(this), maxWithdrawals);
        }
    }

    function validatePhaseTransition(VALIDATOR_PHASE _currentPhase, VALIDATOR_PHASE _newPhase) public pure returns (bool) {
        bool pass;

        // Transition rules
        if (_currentPhase == VALIDATOR_PHASE.NOT_INITIALIZED) {
            pass = (_newPhase == VALIDATOR_PHASE.STAKE_DEPOSITED);
        } else if (_currentPhase == VALIDATOR_PHASE.STAKE_DEPOSITED) {
            pass = (_newPhase == VALIDATOR_PHASE.LIVE || _newPhase == VALIDATOR_PHASE.NOT_INITIALIZED || _newPhase == VALIDATOR_PHASE.WAITING_FOR_APPROVAL);
        } else if (_currentPhase == VALIDATOR_PHASE.WAITING_FOR_APPROVAL) {
            pass = (_newPhase == VALIDATOR_PHASE.LIVE || _newPhase == VALIDATOR_PHASE.NOT_INITIALIZED);
        } else if (_currentPhase == VALIDATOR_PHASE.LIVE) {
            pass = (_newPhase == VALIDATOR_PHASE.EXITED || _newPhase == VALIDATOR_PHASE.BEING_SLASHED);
        } else if (_currentPhase == VALIDATOR_PHASE.BEING_SLASHED) {
            pass = (_newPhase == VALIDATOR_PHASE.EXITED);
        } else if (_currentPhase == VALIDATOR_PHASE.EXITED) {
            pass = (_newPhase == VALIDATOR_PHASE.FULLY_WITHDRAWN);
        } else {
            pass = false;
        }

        require(pass, "INVALID_PHASE_TRANSITION");
        return pass;
    }

    function _onlyEtherFiNodeManagerContract() internal view {
        require(msg.sender == etherFiNodesManager, "INCORRECT_CALLER");
    } 

    //--------------------------------------------------------------------------------------
    //---------------------------------  Signatures-  --------------------------------------
    //--------------------------------------------------------------------------------------

    /**
     * @dev Should return whether the signature provided is valid for the provided data
     * @param _digestHash   Hash of the data to be signed
     * @param _signature Signature byte array associated with _data
    */
    function isValidSignature(bytes32 _digestHash, bytes memory _signature) public view override returns (bytes4 magicValue) {
        bytes32 NODE_ADMIN_ROLE = keccak256("EFNM_NODE_ADMIN_ROLE");
        (address signer, ) = ECDSA.tryRecover(_digestHash, _signature);
        bool isAdmin = IEtherFiNodesManager(etherFiNodesManager).roleRegistry().hasRole(NODE_ADMIN_ROLE, signer);
        return isAdmin ? this.isValidSignature.selector : bytes4(0xffffffff);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyEtherFiNodeManagerContract() {
        _onlyEtherFiNodeManagerContract();
        _;
    }

    modifier ensureLatestVersion() {
        require(version == 1, "NEED_TO_MIGRATE");
        _;
    }
}

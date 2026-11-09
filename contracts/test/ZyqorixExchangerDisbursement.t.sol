// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ExchangerDisbursement} from "../exchangerdisbursement.sol";
import {USDTMock} from "../usdtmock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

// A wallet that rejects native BNB — used to prove the native-DoS trust note.
contract RejectNative {
    receive() external payable { revert("nope"); }
}

contract ZyqorixExchangerDisbursementTest is Test {
    /// @dev USDT's BSC mainnet address, hardcoded in funder, gateway, liquidity and the exchanger.
    address constant USDT_ADDR = 0x55d398326f99059fF775485246999027B3197955;
    ExchangerDisbursement disb;
    USDTMock usdt;

    address owner = makeAddr("owner");
    address a1 = makeAddr("a1");
    address a2 = makeAddr("a2");
    address a3 = makeAddr("a3");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.etch(USDT_ADDR, type(USDTMock).runtimeCode);
        usdt = USDTMock(USDT_ADDR);
        disb = new ExchangerDisbursement(owner);
    }

    function _addThree() internal {
        vm.startPrank(owner);
        disb.addExchanger(a1);
        disb.addExchanger(a2);
        disb.addExchanger(a3);
        vm.stopPrank();
    }

    // ── membership / access control ──

    function test_usdtIsTheMainnetAddress() public view {
        assertEq(address(disb.usdt()), USDT_ADDR);
    }

    function test_addExchanger_onlyOwner() public {
        vm.prank(owner);
        disb.addExchanger(a1);
        assertTrue(disb.isExchanger(a1));
        assertEq(disb.exchangerCount(), 1);
    }

    function test_addExchanger_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        disb.addExchanger(a1);
    }

    function test_addExchanger_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(ExchangerDisbursement.ZeroAddress.selector);
        disb.addExchanger(address(0));
    }

    function test_addExchanger_revertsOnDuplicate() public {
        vm.startPrank(owner);
        disb.addExchanger(a1);
        vm.expectRevert(ExchangerDisbursement.AlreadyExchanger.selector);
        disb.addExchanger(a1);
        vm.stopPrank();
    }

    function test_removeExchanger_onlyOwner() public {
        vm.startPrank(owner);
        disb.addExchanger(a1);
        disb.removeExchanger(a1);
        vm.stopPrank();
        assertFalse(disb.isExchanger(a1));
        assertEq(disb.exchangerCount(), 0);
    }

    function test_removeExchanger_revertsForNonOwner() public {
        vm.prank(owner);
        disb.addExchanger(a1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        disb.removeExchanger(a1);
    }

    function test_removeExchanger_revertsIfNotPresent() public {
        vm.prank(owner);
        vm.expectRevert(ExchangerDisbursement.NotExchanger.selector);
        disb.removeExchanger(a1);
    }

    // ── disburseFunding (USDT) ──

    function test_disburseFunding_splitsEqually() public {
        _addThree();
        usdt.mint(address(disb), 300 ether);
        vm.prank(a1);
        disb.disburseFunding();
        assertEq(usdt.balanceOf(a1), 100 ether);
        assertEq(usdt.balanceOf(a2), 100 ether);
        assertEq(usdt.balanceOf(a3), 100 ether);
        assertEq(usdt.balanceOf(address(disb)), 0);
    }

    function test_disburseFunding_leavesDustRemainder() public {
        _addThree();
        usdt.mint(address(disb), 301); // 301 / 3 = 100 each, 1 wei remainder stays
        vm.prank(a2);
        disb.disburseFunding();
        assertEq(usdt.balanceOf(a1), 100);
        assertEq(usdt.balanceOf(a2), 100);
        assertEq(usdt.balanceOf(a3), 100);
        assertEq(usdt.balanceOf(address(disb)), 1); // rolls into next round
    }

    function test_disburseFunding_onlyMember() public {
        _addThree();
        usdt.mint(address(disb), 300 ether);
        vm.expectRevert(ExchangerDisbursement.NotExchanger.selector);
        vm.prank(stranger);
        disb.disburseFunding();
    }

    function test_disburseFunding_revertsNoExchangers() public {
        // owner is not a member; add then remove all -> but caller must be a member to reach the check.
        // Instead: a member calls after being the only one, but with zero balance handled separately.
        vm.prank(owner);
        disb.addExchanger(a1);
        usdt.mint(address(disb), 100 ether);
        vm.prank(owner);
        disb.removeExchanger(a1);
        // now a1 is no longer a member -> onlyMember guard trips first
        vm.expectRevert(ExchangerDisbursement.NotExchanger.selector);
        vm.prank(a1);
        disb.disburseFunding();
    }

    function test_disburseFunding_revertsNothingToDisburse() public {
        _addThree();
        // balance 2 with 3 members -> share == 0
        usdt.mint(address(disb), 2);
        vm.expectRevert(ExchangerDisbursement.NothingToDisburse.selector);
        vm.prank(a1);
        disb.disburseFunding();
    }

    function test_disburse_reflectsCurrentMembership() public {
        _addThree();
        vm.prank(owner);
        disb.removeExchanger(a3); // only a1, a2 now
        usdt.mint(address(disb), 200 ether);
        vm.prank(a1);
        disb.disburseFunding();
        assertEq(usdt.balanceOf(a1), 100 ether);
        assertEq(usdt.balanceOf(a2), 100 ether);
        assertEq(usdt.balanceOf(a3), 0); // removed before disbursement
    }

    // ── generic token ──

    function test_disburseToken_generic() public {
        _addThree();
        MockUSDT other = new MockUSDT();
        other.mint(address(disb), 90 ether);
        vm.prank(a1);
        disb.disburseToken(IERC20(address(other)));
        assertEq(other.balanceOf(a1), 30 ether);
        assertEq(other.balanceOf(a2), 30 ether);
        assertEq(other.balanceOf(a3), 30 ether);
    }

    // ── native BNB ──

    function test_disburseNative_splitsEqually() public {
        _addThree();
        vm.deal(address(disb), 3 ether);
        vm.prank(a1);
        disb.disburseNative();
        assertEq(a1.balance, 1 ether);
        assertEq(a2.balance, 1 ether);
        assertEq(a3.balance, 1 ether);
    }

    function test_disburseNative_revertsOnRejectingRecipient() public {
        RejectNative bad = new RejectNative();
        vm.startPrank(owner);
        disb.addExchanger(a1);
        disb.addExchanger(address(bad));
        vm.stopPrank();
        vm.deal(address(disb), 2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ExchangerDisbursement.NativeTransferFailed.selector, address(bad))
        );
        vm.prank(a1);
        disb.disburseNative();
    }

    // ── views ──

    function test_views() public {
        _addThree();
        usdt.mint(address(disb), 300 ether);
        assertEq(disb.exchangerCount(), 3);
        assertEq(disb.pendingShare(IERC20(address(usdt))), 100 ether);
        address[] memory list = disb.exchangers();
        assertEq(list.length, 3);
    }

    function test_ownerIsSet() public view {
        assertEq(disb.owner(), owner);
        assertEq(address(disb.usdt()), address(usdt));
    }
}

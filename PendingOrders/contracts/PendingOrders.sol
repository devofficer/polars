pragma solidity ^0.7.4;

// "SPDX-License-Identifier: MIT"

import "./DSMath.sol";
import "./SafeMath.sol";
import "./IERC20.sol";
import "./Ownable.sol";
import "./ISecondaryPool.sol";

contract PendingOrders is DSMath, Ownable {

	using SafeMath for uint256;
	
	struct Order {
		address orderer;
		uint amount;
		bool isWhite;
		uint eventId;
		bool isPending; // True when placed, False when canceled or executed.
		bool isExecuted; // False when placed, True when executed.
		uint placingPrice; // Price when placing order
		uint executingPrice; // Price when executing order
	}
	event orderCreated(uint);
	event orderCanceled(uint);
	event collateralWithdrew(uint);
	event contractOwnerChanged(address);
	event secondaryPoolAddressChanged(address);
	event eventContractAddressChanged(address);
	event feeWithdrawAddressChanged(address);
	event feeWithdrew(uint);
	event feeChanged(uint);

	// "ordersCount" indicates how many orders have been placed so far.
	// Array Orders stores all orders placed by users.
	uint ordersCount;
	Order[] public Orders;

	// Max and min prices are defined manually as following since it's meaningless in this contract.
	uint public _maxPrice = 100 * WAD;
	uint public _minPrice = 0 * WAD;

	// Withdraw fee of collateral tokens are initiated as 0.01%, but can be still changed.
	uint public _FEE = 1e14;

	// Fee collected so far is kept in _collectedFee
	uint public _collectedFee;

	IERC20 public _collateralToken;
	ISecondaryPool public _secondaryPool;

	address public _feeWithdrawAddress;
	address public _eventContractAddress;
	address public _secondaryPoolAddress;

	constructor (
		address secondaryPoolAddress,
		address collateralTokenAddress,
		address feeWithdrawAddress,
        address eventContractAddress
	) {
		require(
			secondaryPoolAddress != address(0),
			"SECONDARY POOL ADDRESS SHOULD NOT BE NULL"
		);
		require(
			collateralTokenAddress != address(0),
			"COLLATERAL TOKEN ADDRESS SHOULD NOT BE NULL"
		);
		require(
			feeWithdrawAddress != address(0),
			"FEE WITHDRAW ADDRESS SHOULD NOT BE NULL"
		);
		require(
			eventContractAddress != address(0),
			"EVENT ADDRESS SHOULD NOT BE NULL"
		);
		_secondaryPoolAddress = secondarypoolAddress;
		_secondaryPool = ISecondaryPool(_secondaryPoolAddress);
		_collateralToken = IERC20(collateralTokenAddress);
		_feeWithdrawAddress = feeWithdrawAddress;
		_eventContractAddress = eventContractAddress;
	}

	// Modifier to ensure call has been made by event contract
	modifier onlyEventContract {
        require(
            msg.sender == _eventContractAddress,
            "CALLER SHOULD BE EVENT CONTRACT"
        );
        _;
    }

	function createOrder(uint _amount, bool _isWhite, uint _eventId) external {
		require(
			_collateralToken.balanceOf(msg.sender) >= _amount,
			"NOT ENOUGH COLLATERAL IN USER'S ACCOUNT"
		);
		Order memory _newOrder = Order(
			msg.sender,
			_amount,
			_isWhite,
			_eventId,
			true,
			false,
			_isWhite? _secondaryPool._whitePrice(): _secondaryPool._blackPrice(),
			0
		);

		// Gather collateral from the orderer.

		_collateralToken.transferFrom(msg.sender, address(this), _amount);

		Orders.push(_newOrder);
		ordersCount++;
		emit orderCreated(ordersCount);
	}

	function cancelOrder(uint _orderId) external {
		require(
			Orders[_orderId].isPending,
			"Selected order is not available at the moment"
		);
		Order storage _orderToCancel = Orders[_orderId];
		require(msg.sender == _orderToCancel.orderer, "Only orderer can cancel the order");

		// Return collateral token to the user
		require(
		    _collateralToken.balanceOf(address(this)) >= _orderToCancel.amount,
		    "Insufficient collateral token in PendingOrders contract"
		);
		_collateralToken.transfer(
			_orderToCancel.orderer,
			_orderToCancel.amount
		);

		_orderToCancel.isPending = false;
		emit orderCanceled(_orderId);
	}

	// Total W/B token amounts for current event.
	uint whiteTokenAmount;
	uint blackTokenAmount;

	function eventStart(uint _eventId) external onlyEventContract {

		// Calculate total W/B token amount ordered to this event.
		for (uint i = 0; i < Orders.length; i++) {
			Order storage _order = Orders[i];
			if (_order.eventId == _eventId && _order.isPending) {
				uint tokenAmount = wdiv(_order.amount, _order.placingPrice);
				if (_order.isWhite) {
					whiteTokenAmount = whiteTokenAmount.add(tokenAmount);
				} else {
					blackTokenAmount = blackTokenAmount.add(tokenAmount);
				}
			}
		}

		// Buy W/B tokens for this event.
		_secondaryPool.buyWhite(_maxPrice, whiteTokenAmount);
		_secondaryPool.buyBlack(_maxPrice, blackTokenAmount);
	}

	function eventEnd(uint _eventId) external onlyEventContract {

		// Find orders for this event and change details
		for (uint i = 0; i < Orders.length; i++) {
			Order storage _order = Orders[i];
			if (_order.eventId == _eventId && _order.isPending) {
				uint newPrice = _order.isWhite
					? _secondaryPool._whitePrice()
					: _secondaryPool._blackPrice();
				_order.executingPrice = newPrice;
				_order.isExecuted = true;
				_order.isPending = false;
			}
		}

		// Sell W/B tokens for this event.
		_secondaryPool.sellWhite(_minPrice, whiteTokenAmount);
		_secondaryPool.sellBlack(_minPrice, blackTokenAmount);
		whiteTokenAmount = 0;
		blackTokenAmount = 0;
	}

	function withdrawCollateral() external {
		
		// Find all executed orders of the user and sum up collaterals to return.
		uint totalCollateral;		
		for (uint i = 0; i < Orders.length; i++) {
			Order storage _order = Orders[i];
			if (_order.orderer == msg.sender && _order.isExecuted) {
				totalCollateral = totalCollateral.add(
					wmul(wdiv(_order.amount, _order.placingPrice), _order.executingPrice)
				);
			}
		}

		uint feeAmount = wmul(totalCollateral, _FEE);
		uint withdrawAmount = totalCollateral.sub(feeAmount);
		_collateralToken.transfer(msg.sender, withdrawAmount);

		_collectedFee = _collectedFee.add(feeAmount);
		emit collateralWithdrew(withdrawAmount);
	}

	function changeContractOwner(address _newOwnerAddress) external onlyOwner {
		require(
			_newOwnerAddress != address(0),
			"NEW OWNER ADDRESS SHOULD NOT BE NULL"
		);
		transferOwnership(_newOwnerAddress);
		emit contractOwnerChanged(_newOwnerAddress);
	}

	function changeSecondaryPoolAddress(address _newPoolAddress) external onlyOwner {
		require(
			_newPoolAddress != address(0),
			"NEW SECONDARYPOOL ADDRESS SHOULD NOT BE NULL"
		);
		_secondaryPoolAddress = _newPoolAddress;
		emit secondaryPoolAddressChanged(_secondaryPoolAddress);
	}

	function changeEventContractAddress(address _newEventAddress) external onlyOwner {
		require(
			_newEventAddress != address(0),
			"NEW EVENT ADDRESS SHOULD NOT BE NULL"
		);
		_eventContractAddress = _newEventAddress;
		emit eventContractAddressChanged(_eventContractAddress);
	}

	function changeFeeWithdrawAddress(address _newFeeWithdrawAddress) external onlyOwner {
		require(
			_newFeeWithdrawAddress != address(0),
			"NEW WITHDRAW ADDRESS SHOULD NOT BE NULL"
		);
		_feeWithdrawAddress = _newFeeWithdrawAddress;
		emit feeWithdrawAddressChanged(_feeWithdrawAddress);
	}

	function withdrawFee() external onlyOwner {
	    require(
	        _collateralToken.balanceOf(address(this)) >= _collectedFee,
	        "INSUFFICIENT TOKEN(THAT IS LOWER THAN EXPECTED COLLECTEDFEE) IN PENDINGORDERS CONTRACT"
	    );
		_collateralToken.transfer(_feeWithdrawAddress, _collectedFee);
		_collectedFee = 0;
		emit feeWithdrew(_collectedFee);
	}

	function changeFee(uint _newFEE) external onlyOwner {
		_FEE = _newFEE;
		emit feeChanged(_FEE);
	}
}
// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface IChannel {
  /// When claiming reward, user should pay commissions to the channel partner if bind.
  ///
  /// @param partnerId the id of channel partner
  /// @param reward the reward for total staked tx
  /// @return remainingReward the remain reward after pay commission.
  function payCommissionById(uint32 partnerId, uint256 reward) external returns (uint256 remainingReward);

  /// When claiming reward, user should pay commissions to the channel partner if bind.
  ///
  /// @param delegator the delegator address
  /// @param amount the staked amount
  /// @param reward the amount of rewards collected
  /// @return remainingReward the remain reward after pay commission.
  function payCommissions(address delegator, uint256 amount, uint256 reward) external returns (uint256 remainingReward);


  /// Reset commission for partner
  ///
  /// @param partner the channel partner
  /// @return commission Amount claimed
  /// @return feeAddress the fee address
  function resetCommission(address partner) external returns (uint256 commission, address feeAddress);
}

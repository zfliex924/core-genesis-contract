// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.24;

import "./lib/Memory.sol";
import "./lib/RLPDecode.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./interface/IParamSubscriber.sol";
import "./System.sol";

/// Shared grade configuration for staking multipliers.
/// - grades: lock duration grades (used by NativeAgent and ZecAgent)
/// - dualGrades: dual staking ratio grades (used by ZecAgent)
contract GradeManager is System, IParamSubscriber {

  using RLPDecode for bytes;
  using RLPDecode for RLPDecode.RLPItem;

  struct Grade {
    uint256 threshold;     // lock days or dual staking ratio
    uint256 multiplier;    // DENOMINATOR = 10000 = 1.0x
  }

  Grade[] public grades;       // lock duration grades
  Grade[] public dualGrades;   // dual staking ratio grades

  event GradesUpdated(string indexed name, uint256 count);

  function init() external onlyNotInit {
    // Lock duration grades (12 tiers)
    grades.push(Grade(1,   10000));   // Tier 1:  100%
    grades.push(Grade(14,  20000));   // Tier 2:  200%
    grades.push(Grade(30,  30000));   // Tier 3:  300%
    grades.push(Grade(60,  40000));   // Tier 4:  400%
    grades.push(Grade(90,  50000));   // Tier 5:  500%
    grades.push(Grade(120, 60000));   // Tier 6:  600%
    grades.push(Grade(150, 70000));   // Tier 7:  700%
    grades.push(Grade(180, 80000));   // Tier 8:  800%
    grades.push(Grade(210, 85000));   // Tier 9:  850%
    grades.push(Grade(270, 90000));   // Tier 10: 900%
    grades.push(Grade(330, 95000));   // Tier 11: 950%
    grades.push(Grade(365, 100000));  // Tier 12: 1000%

    // Dual staking ratio grades
    dualGrades.push(Grade(0, 10000));   // no dual stake: 1.0x
    dualGrades.push(Grade(1, 11000));   // ratio >= 1: 1.1x
    dualGrades.push(Grade(2, 13000));   // ratio >= 2: 1.3x
    dualGrades.push(Grade(5, 15000));   // ratio >= 5: 1.5x

    alreadyInit = true;
  }

  /// Get lock duration multiplier
  function getMultiplier(uint256 lockValue) external view returns (uint256) {
    return _lookup(grades, lockValue);
  }

  /// Get dual staking multiplier
  function getDualMultiplier(uint256 ratio) external view returns (uint256) {
    return _lookup(dualGrades, ratio);
  }

  function getGrades() external view returns (Grade[] memory) {
    return grades;
  }

  function getDualGrades() external view returns (Grade[] memory) {
    return dualGrades;
  }

  /// Update grades via governance
  /// key = "grades" or "dualGrades"
  /// value = RLP([ RLP([threshold, multiplier]), ... ])
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (Memory.compareStrings(key, "grades")) {
      _updateGrades(grades, value);
      emit GradesUpdated("grades", grades.length);
    } else if (Memory.compareStrings(key, "dualGrades")) {
      _updateGrades(dualGrades, value);
      emit GradesUpdated("dualGrades", dualGrades.length);
    } else {
      revert UnsupportedGovParam(key);
    }
    emit paramChange(key, value);
  }

  function _lookup(Grade[] storage arr, uint256 val) internal view returns (uint256) {
    uint256 multiplier = SatoshiPlusHelper.DENOMINATOR;
    for (uint256 i = arr.length; i > 0; --i) {
      if (val >= arr[i - 1].threshold) {
        multiplier = arr[i - 1].multiplier;
        break;
      }
    }
    return multiplier;
  }

  function _updateGrades(Grade[] storage arr, bytes calldata value) internal {
    RLPDecode.RLPItem[] memory items = value.toRLPItem().toList();
    require(items.length > 0, "empty grades");
    while (arr.length > 0) { arr.pop(); }
    for (uint256 i = 0; i < items.length; i++) {
      RLPDecode.RLPItem[] memory pair = items[i].toList();
      uint256 threshold = RLPDecode.toUint(pair[0]);
      uint256 multiplier = RLPDecode.toUint(pair[1]);
      if (i == 0) {
        require(multiplier >= SatoshiPlusHelper.DENOMINATOR, "multiplier too low");
      } else {
        require(threshold > arr[i - 1].threshold, "threshold disorder");
        require(multiplier > arr[i - 1].multiplier, "multiplier disorder");
      }
      arr.push(Grade(threshold, multiplier));
    }
  }
}

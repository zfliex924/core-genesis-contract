// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.24;

interface IParamSubscriber {
    function updateParam(string calldata key, bytes calldata value) external;
}
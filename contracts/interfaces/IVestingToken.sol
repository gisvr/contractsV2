/**
 * Copyright 2017-2020, bZeroX, LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0.
 */

pragma solidity >=0.5.0 <0.6.0;

import "./IERC20.sol";


contract IVestingToken is IERC20 {
    function claimedBalanceOf(
        address _owner)
        external
        view
        returns (uint256);

    function totalVested()
        external
        view
        returns (uint256);
}

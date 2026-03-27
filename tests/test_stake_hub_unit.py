import pytest
import brownie
import rlp
from .common import *
from collections import OrderedDict
from .delegate import *

MIN_INIT_DELEGATE_VALUE = 0
CANDIDATE_REGISTER_MARGIN = 0
candidate_hub_instance = None
core_agent_instance = None
btc_light_client_instance = None
required_coin_deposit = 0
LOCK_SCRIPT = '0480db8767b17576a914574fdd26858c28ede5225a809f747c01fcc1f92a88ac'
TX_FEE = Web3.to_wei(1, 'ether')
# the tx fee is 1 ether
actual_block_reward = 0
COIN_REWARD = 0
BLOCK_REWARD = 0
stake_manager = StakeManager()
round_reward_manager = RoundRewardManager()


@pytest.fixture()
def set_candidate():
    operators = []
    consensuses = []
    for operator in accounts[5:8]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    return operators, consensuses


@pytest.fixture(scope="module", autouse=True)
def set_up(min_init_delegate_value, core_agent, candidate_hub, btc_agent, hash_power_agent,
           btc_light_client, validator_set, stake_hub, btc_stake, system_reward, gov_hub):
    global MIN_INIT_DELEGATE_VALUE
    global CANDIDATE_REGISTER_MARGIN
    global candidate_hub_instance
    global core_agent_instance
    global required_coin_deposit
    global btc_light_client_instance
    global actual_block_reward
    global COIN_REWARD
    global BLOCK_REWARD
    global BTC_STAKE, STAKE_HUB, BTC_AGENT, CORE_AGENT, HASH_POWER_AGENT, TOTAL_REWARD, GOV_HUB
    global COIN_REWARD, BTC_REWARD, HASH_REWARD, ZEC_REWARD
    BTC_STAKE = btc_stake
    STAKE_HUB = stake_hub
    BTC_AGENT = btc_agent
    CORE_AGENT = core_agent
    HASH_POWER_AGENT = hash_power_agent
    GOV_HUB = gov_hub
    candidate_hub_instance = candidate_hub
    core_agent_instance = core_agent
    btc_light_client_instance = btc_light_client
    MIN_INIT_DELEGATE_VALUE = min_init_delegate_value
    CANDIDATE_REGISTER_MARGIN = candidate_hub.requiredMargin()
    required_coin_deposit = core_agent.requiredCoinDeposit()
    block_reward = validator_set.blockReward()
    block_reward_incentive_percent = validator_set.blockRewardIncentivePercent()
    total_block_reward = block_reward + TX_FEE
    actual_block_reward = total_block_reward * (100 - block_reward_incentive_percent) // 100
    tx_fee = 100
    BLOCK_REWARD = (block_reward + tx_fee) * ((100 - block_reward_incentive_percent) / 100)
    TOTAL_REWARD = BLOCK_REWARD // 2
    COIN_REWARD = TOTAL_REWARD * HardCap.CORE_HARD_CAP // HardCap.SUM_HARD_CAP
    BTC_REWARD = TOTAL_REWARD * HardCap.BTC_HARD_CAP // HardCap.SUM_HARD_CAP
    HASH_REWARD = TOTAL_REWARD * HardCap.POWER_HARD_CAP // HardCap.SUM_HARD_CAP
    ZEC_REWARD = TOTAL_REWARD * HardCap.ZEC_HARD_CAP // HardCap.SUM_HARD_CAP
    STAKE_HUB = stake_hub
    system_reward.setOperator(stake_hub.address)
    btc_agent.setAssetWeight(1)


@pytest.fixture(scope="module", autouse=True)
def deposit_for_reward(validator_set, system_reward):
    accounts[99].transfer(validator_set.address, Web3.to_wei(100000, 'ether'))
    accounts[99].transfer(system_reward.address, Web3.to_wei(100000, 'ether'))


def test_validators_and_rewards_length_mismatch_revert(validator_set):
    validators = [accounts[1], accounts[2]]
    reward_list = [1000]
    value_sum = sum(reward_list)
    with brownie.reverts('the length of validators and rewardList should be equal'):
        validator_set.addRoundRewardMock(validators, reward_list, 100,
                                         {'from': accounts[0], 'value': value_sum})


def test_only_validator_can_call_add_round_reward(stake_hub):
    validators = [accounts[1], accounts[2]]
    reward_list = [1000, 1000]
    value_sum = sum(reward_list)
    with brownie.reverts('the msg sender must be validatorSet contract'):
        stake_hub.addRoundReward(validators, reward_list, 100,
                                 {'from': accounts[0], 'value': value_sum})


def test_add_round_reward_success(validator_set, core_agent, btc_light_client, btc_stake, candidate_hub, stake_hub):
    round_tag = 100
    validators = [accounts[1], accounts[2]]
    reward_list = [1000, 2000]
    value_sum = sum(reward_list)
    power_value = 5
    core_value = 100
    btc_value = 10
    for validator in validators:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
        btc_stake.setCandidateMap(validator, btc_value, btc_value, [])
    candidate_hub.getScoreMock(validators, round_tag)
    tx = validator_set.addRoundRewardMock(validators, reward_list, round_tag,
                                          {'from': accounts[0], 'value': value_sum})
    for index, round_reward in enumerate(tx.events['roundReward']):
        assert len(round_reward['amount']) == len(validators)


def test_no_stake_on_validator(validator_set, core_agent, btc_light_client, btc_stake, candidate_hub, stake_hub):
    round_tag = 100
    validators = [accounts[1], accounts[2]]
    reward_list = [1000, 2000]
    value_sum = sum(reward_list)
    candidate_hub.getScoreMock(validators, round_tag)
    tx = validator_set.addRoundRewardMock(validators, reward_list, round_tag,
                                          {'from': accounts[0], 'value': value_sum})
    # With hardcap ratio distribution, rewards are distributed to agents regardless of stakes.
    # Each agent receives its hardcap proportion via distributeReward.
    # 4 roundReward events should be emitted (one per asset).
    for round_reward in tx.events['roundReward']:
        assert len(round_reward['amount']) == len(validators)


def test_add_round_reward_no_btc_stake(validator_set, core_agent, candidate_hub,
                                       stake_hub):
    round_tag = 100
    core_value = 100
    validators = [accounts[1], accounts[2]]
    reward_list = [1000, 2000]
    value_sum = sum(reward_list)
    for validator in validators:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
    candidate_hub.getScoreMock(validators, round_tag)
    tx = validator_set.addRoundRewardMock(validators, reward_list, round_tag,
                                          {'from': accounts[0], 'value': value_sum})
    # With hardcap ratio distribution, CORE gets 6000/15000 of each reward
    assert tx.events['roundReward'][0]['amount'] == [r * 6000 // 15000 for r in reward_list]
    # BTC gets 4000/15000 of each reward
    assert tx.events['roundReward'][2]['amount'] == [r * 4000 // 15000 for r in reward_list]


def test_reward_without_stake(validator_set, core_agent, btc_light_client, btc_stake, candidate_hub, stake_hub):
    round_tag = 100
    validators = [accounts[1], accounts[2]]
    reward_list = [0, 0]
    value_sum = sum(reward_list)
    power_value = 5
    core_value = 100
    btc_value = 10
    for validator in validators:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
        btc_stake.setCandidateMap(validator, btc_value, btc_value, [])
    candidate_hub.getScoreMock(validators, round_tag)
    tx = validator_set.addRoundRewardMock(validators, reward_list, round_tag,
                                          {'from': accounts[0], 'value': value_sum})
    # With zero rewards, all 4 asset round rewards should be [0, 0]
    for round_reward in tx.events['roundReward']:
        assert round_reward['amount'] == (0, 0)


def test_only_candidate_can_call(validator_set, stake_hub):
    round_tag = 100
    validators = [accounts[1], accounts[2]]
    with brownie.reverts('the msg sender must be candidate contract'):
        stake_hub.getHybridScore(validators, round_tag)


@pytest.mark.parametrize("test", [
    pytest.param({'add_core': 10e18}, id="core"),
    pytest.param({'add_hash': 100}, id="hash"),
    pytest.param({'add_btc': 10e8}, id="btc"),
    pytest.param({'add_core': 1e18, 'add_hash': 200}, id="core & hash"),
    pytest.param({'add_core': 1e18, 'add_btc': 100e8}, id="core & btc"),
    pytest.param({'add_hash': 200, 'add_btc': 100e8}, id="hash & btc"),
    pytest.param({'add_core': 10e8, 'add_hash': 200, 'add_btc': 1000e8}, id="core & hash & btc"),
    pytest.param({'add_core': 1e8, 'add_hash': 100, 'add_btc': 10e8}, id="core & hash & btc"),
    pytest.param({'add_core': 0, 'add_hash': 0, 'add_btc': 0}, id="core & hash & btc"),
])
def test_get_hybrid_score_success(core_agent, btc_light_client, btc_stake, candidate_hub, stake_hub,
                                  hash_power_agent, btc_agent, zec_agent, test):
    round_tag = 100
    validators = [accounts[1], accounts[2]]
    core_value = test.get('add_core', 0)
    power_value = test.get('add_hash', 0)
    btc_value = test.get('add_btc', 0)
    zec_value = 0
    values = [core_value, power_value, btc_value, zec_value]
    for validator in validators[:1]:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
        btc_stake.setCandidateMap(validator, btc_value, btc_value, [])
    tx = candidate_hub.getScoreMock(validators, round_tag)
    scores = tx.return_value
    hard_cap = [6000, 2000, 4000, 3000]
    factors = []
    factor0 = 0
    for index, h in enumerate(hard_cap):
        factor = 1
        if index == 0:
            factor0 = 1
        if index > 0 and values[0] != 0 and values[index] != 0:
            factor = (factor0 * core_value) * h // hard_cap[0] // values[index]
        factors.append(factor)
    assets = [core_agent, hash_power_agent, btc_agent, zec_agent]
    for index, asset in enumerate(assets):
        factor = stake_hub.stateMap(asset)
        assert factor == [values[index], int(factors[index])]
    assert scores[1] == 0


def test_calculate_factor_success(core_agent, btc_light_client, btc_stake, candidate_hub, stake_hub,
                                  hash_power_agent, btc_agent):
    round_tag = 100
    validators = [accounts[1]]
    core_value = 100e18
    power_value = 200
    for validator in validators[:1]:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
    candidate_hub.getScoreMock(validators, round_tag)


def test_two_rounds_score_calculation_success(core_agent, btc_light_client, btc_stake, candidate_hub, stake_hub,
                                              hash_power_agent, btc_agent):
    round_tag = 100
    validators = [accounts[1]]
    core_value = 100e18
    power_value = 200
    btc_value = 200
    for validator in validators[:1]:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
    candidate_hub.getScoreMock(validators, round_tag)
    btc_stake.setCandidateMap(validators[0], btc_value, btc_value, [])
    candidate_hub.getScoreMock(validators, round_tag)


def test_validators_score_calculation_success(core_agent, btc_light_client, btc_stake, candidate_hub, stake_hub,
                                              hash_power_agent, btc_agent):
    round_tag = 100
    validators = [accounts[1], accounts[2]]
    core_value = 100e18
    power_value = 200
    btc_value = 200
    for validator in validators:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
        btc_stake.setCandidateMap(validators[0], btc_value, btc_value, [])
    tx = candidate_hub.getScoreMock(validators, round_tag)
    scores = tx.return_value
    assert len(scores) == len(validators)


def test_only_candidate_can_call_set_new_round(stake_hub):
    with brownie.reverts("the msg sender must be candidate contract"):
        stake_hub.setNewRound(accounts[:2], 100)


def test_set_new_round_success(stake_hub, core_agent, btc_stake):
    round_tag = 100
    update_system_contract_address(stake_hub, candidate_hub=accounts[0])
    stake_hub.setNewRound(accounts[:2], round_tag)
    assert core_agent.roundTag() == btc_stake.roundTag() == round_tag


def __mock_stake_hub_reward():
    accounts[3].transfer(STAKE_HUB, Web3.to_wei(1, 'ether'))


def test_claim_reward_staked_core_amount_different(stake_hub, btc_agent, core_agent, set_candidate):
    stake_manager.set_lp_rates([[0, 5000], [5000, 8000], [8000, 10000], [10000, 15000]])
    operators, consensuses = set_candidate
    delegate_coin_success(operators[1], accounts[0], 4999)
    delegate_btc_success(operators[0], accounts[0], 1, LOCK_SCRIPT)
    turn_round()
    turn_round(consensuses)
    stake_manager.set_is_stake_hub_active(True)
    tracker = get_tracker(accounts[0])
    tx = stake_hub.claimReward()
    expect_event(tx, 'claimedRewardBtcTx', {
        'dualStakingRate': 0
    })
    assert abs(tracker.delta() - (COIN_REWARD + BTC_REWARD)) <= 1


def test_claim_reward_staked_core_amount_different_with_reward(stake_hub, btc_agent, core_agent, set_candidate):
    stake_manager.set_lp_rates([[0, 3000], [4000, 5000], [7000, 10000], [10000, 15000]])
    operators, consensuses = set_candidate

    delegate_coin_success(operators[1], accounts[0], 2000)
    delegate_coin_success(operators[2], accounts[0], 2000)
    delegate_btc_success(operators[0], accounts[0], 1, LOCK_SCRIPT)
    turn_round()
    delegate_coin_success(operators[1], accounts[0], 3000)
    turn_round(consensuses, round_count=2)
    stake_manager.set_is_stake_hub_active(True)
    tracker = get_tracker(accounts[0])
    tx = stake_hub.claimReward()
    claimed = tx.events['claimedReward']
    actual_rewards = claimed['amounts']
    assert actual_rewards[0] == COIN_REWARD * 4
    assert actual_rewards[1] == 0
    assert abs(actual_rewards[2] - BTC_REWARD * 2) <= 1
    assert actual_rewards[3] == 0
    assert tracker.delta() == sum(actual_rewards)


@pytest.mark.parametrize("operator", ['tr', 'de', 'un'])
def test_claim_reward_staked_core_amount_equal(stake_hub, btc_agent, core_agent, set_candidate, operator):
    stake_manager.set_is_stake_hub_active(True)
    stake_manager.set_lp_rates([[0, 3000], [4000, 5000], [7000, 10000], [10000, 15000]])
    operators, consensuses = set_candidate
    delegate_coin_success(operators[2], accounts[0], 14000)
    delegate_btc_success(operators[0], accounts[0], 1, LOCK_SCRIPT)
    delegate_btc_success(operators[1], accounts[0], 1, LOCK_SCRIPT)
    turn_round()
    # Dual staking removed — dualStakingRate is always 0, BTC reward is full
    dualStakingRate0 = 0
    dualStakingRate1 = 0
    coin_reward = COIN_REWARD
    btc_reward = BTC_REWARD + BTC_REWARD
    if operator == 'tr':
        delegate_coin_success(operators[0], accounts[0], MIN_INIT_DELEGATE_VALUE * 2)
    elif operator == 'de':
        delegate_coin_success(operators[0], accounts[0], MIN_INIT_DELEGATE_VALUE * 2)
    elif operator == 'un':
        undelegate_coin_success(operators[2], accounts[0], 7000)
        coin_reward = COIN_REWARD // 2
    turn_round(consensuses)
    tx = stake_hub.claimReward()
    expect_event(tx, 'claimedRewardBtcTx', {
        'dualStakingRate': dualStakingRate0
    }, idx=0)
    expect_event(tx, 'claimedRewardBtcTx', {
        'dualStakingRate': dualStakingRate1
    }, idx=1)
    expect_event(tx, 'claimedReward', {
        'delegator': accounts[0],
        'amounts': [coin_reward, 0, btc_reward, 0]
    })


def test_claim_reward_change_round_equal_and_staked_core_equal(stake_hub, core_agent, btc_agent, set_candidate):
    operators, consensuses = set_candidate
    stake_manager.set_is_stake_hub_active(True)
    stake_manager.set_lp_rates([[0, 10000]])
    delegate_coin_success(operators[0], accounts[0], 10000)
    delegate_btc_success(operators[0], accounts[0], 1, LOCK_SCRIPT)
    turn_round()
    turn_round(consensuses)
    stake_hub.calculateReward(accounts[0])
    get_tracker(accounts[0])
    tx = stake_hub.claimReward()
    coin_reward = TOTAL_REWARD * 6000 // 15000
    btc_reward = TOTAL_REWARD * 4000 // 15000
    expect_event(tx, 'claimedReward', {
        'delegator': accounts[0],
        'amounts': [coin_reward, 0, btc_reward, 0]
    })


def test_claim_reward_change_round_less_than_last(stake_hub, btc_agent, core_agent, set_candidate):
    operators, consensuses = set_candidate
    delegate_coin_success(operators[1], accounts[0], MIN_INIT_DELEGATE_VALUE * 2)
    delegate_btc_success(operators[0], accounts[0], 1, LOCK_SCRIPT)
    turn_round()
    turn_round(consensuses, round_count=3)
    tracker = get_tracker(accounts[0])
    tx = stake_hub.claimReward()
    expect_event(tx, 'claimedReward', {
        'delegator': accounts[0],
        'amounts': [COIN_REWARD * 3, 0, BTC_REWARD * 3, 0]
    })


def test_claim_reward_with_stored_historical_rewards(stake_hub, btc_agent, set_candidate):
    operators, consensuses = set_candidate

    delegate_coin_success(operators[1], accounts[0], MIN_INIT_DELEGATE_VALUE * 2)
    delegate_btc_success(operators[0], accounts[0], 1, LOCK_SCRIPT)
    turn_round()
    turn_round(consensuses)
    stake_hub.calculateReward(accounts[0])
    assert stake_hub.getDelegator(accounts[0])[1] == [COIN_REWARD, 0, BTC_REWARD, 0]
    turn_round(consensuses)
    tx = stake_hub.claimReward()
    expect_event(tx, 'claimedReward', {
        'delegator': accounts[0],
        'amounts': [COIN_REWARD * 2, 0, BTC_REWARD * 2, 0]
    })
    assert sum(stake_hub.getDelegator(accounts[0])[1]) == 0


def test_claim_reward_change_round_update(stake_hub, btc_agent, set_candidate):
    operators, consensuses = set_candidate

    delegate_btc_success(operators[0], accounts[0], 1, LOCK_SCRIPT)
    turn_round()
    turn_round(consensuses)

    initial_delegator = stake_hub.getDelegator(accounts[0])
    initial_change_round = initial_delegator[0]

    turn_round(consensuses)
    turn_round(consensuses)
    stake_hub.claimReward()
    final_delegator = stake_hub.getDelegator(accounts[0])
    final_change_round = final_delegator[0]

    assert final_change_round > initial_change_round


def test_claim_reward_all_asset_types_combined(stake_hub, btc_agent, core_agent, hash_power_agent, set_candidate):
    operators, consensuses = set_candidate
    delegate_coin_success(operators[0], accounts[0], MIN_INIT_DELEGATE_VALUE * 3)
    delegate_btc_success(operators[0], accounts[0], 1, LOCK_SCRIPT)
    delegate_power_success(operators[0], accounts[0], 1)
    turn_round()
    turn_round(consensuses)
    tracker = get_tracker(accounts[0])
    rewards = stake_hub.claimReward().return_value
    assert len(rewards) == 4
    # With hardcap ratio distribution, total reward is split across 4 agents
    # User gets rewards from CORE, HASH, and BTC agents (no ZEC)
    total_claimed = sum(rewards)
    assert tracker.delta() == total_claimed
    assert rewards[0] == COIN_REWARD


# _calculateReward
def test_calculate_reward_success(stake_hub, btc_agent, core_agent, btc_stake, hash_power_agent,
                                  set_candidate):
    operators, consensuses = set_candidate
    delegate_btc_success(operators[0], accounts[0], 1, LOCK_SCRIPT)
    turn_round()
    turn_round(consensuses)
    accounts[3].transfer(stake_hub, Web3.to_wei(1, 'ether'))
    reward = 10000
    actual_rewards = [reward, reward, reward, 0]
    core_agent.setCoreRewardMap(accounts[0], reward, 0)
    hash_power_agent.setPowerRewardMap(accounts[0], reward, 0)
    round_reward_manager.mock_btc_reward_map(operators[0], get_current_round(), reward, 0)
    btc_agent.setIsActive(True)
    stake_hub.setOperators(accounts[3], True)
    rewards = stake_hub.calculateRewardMock(accounts[0]).return_value
    assert rewards == actual_rewards


@pytest.mark.parametrize("lp_rates", [
    [(0, 1000), (1000, 5000), (30000, 10000)],
    [(0, 1000), (1000, 2000), (2000, 5000)],
    [(0, 5000), (12000, 10000), (20000, 12000)],
    [(0, 2000), (8000, 2000), (10000, 5000)],
    [(0, 2000), (10000, 5000), (12000, 2000)]
]
                         )
def test_claim_rewards_multiple_grades(stake_hub, core_agent, validator_set, btc_stake, hash_power_agent, btc_agent,
                                       lp_rates,
                                       set_candidate):
    btc_agent.setAssetWeight(1e10)
    accounts[3].transfer(validator_set.address, Web3.to_wei(10000, 'ether'))
    operators, consensuses = set_candidate
    delegate_coin_success(operators[1], accounts[0], 10000e18)
    delegate_btc_success(operators[0], accounts[0], 1e8, LOCK_SCRIPT)
    turn_round()
    turn_round(consensuses)
    accounts[3].transfer(stake_hub, Web3.to_wei(1, 'ether'))
    reward = 10000
    round_reward_manager.mock_btc_reward_map(operators[0], get_current_round(), reward, 0, 1e8)
    core_agent.setCoreRewardMap(accounts[0], reward, 1000000)
    hash_power_agent.setPowerRewardMap(accounts[0], reward, 10)
    btc_agent.setIsActive(True)
    for lp in lp_rates:
        btc_agent.setLpRates(lp[0], lp[1])
    tx = stake_hub.calculateRewardMock(accounts[0])
    rewards = tx.return_value
    # Dual staking removed — BTC reward is the full reward (no LP rate reduction)
    actual_rewards = [reward, reward, reward, 0]
    assert rewards == actual_rewards


def test_get_assets_success(stake_hub, core_agent, hash_power_agent, btc_agent, zec_agent):
    assets = stake_hub.getAssets()
    assert assets == [['CORE', core_agent.address, 6000], ['HASHPOWER', hash_power_agent.address, 2000],
                      ['BTC', btc_agent.address, 4000], ['ZEC', zec_agent.address, 3000]]


def test_get_delegator_success(stake_hub, set_candidate):
    stake_manager.set_lp_rates([[0, 1000], [2500, 2500], [5000, 5000], [10000, 20000]])
    stake_manager.set_is_stake_hub_active(True)
    stake_manager.set_tlp_rates()
    operators, consensuses = set_candidate
    turn_round()
    delegate_amount = 500000
    btc_value = 100
    delegate_coin_success(operators[0], accounts[0], delegate_amount)
    turn_round(consensuses, round_count=2)
    lock_script = '0480db8767b17576a914574fdd26858c28ede5225a809f747c01fcc1f92a88ac'
    delegate_btc_success(operators[1], accounts[0], btc_value, lock_script)

    delegator_map = stake_hub.getDelegator(accounts[0])
    assert delegator_map == [get_current_round(), [COIN_REWARD, 0, 0, 0]]


def test_onStakeChange_success(stake_hub, set_candidate):
    stake_manager.set_lp_rates([[0, 1000], [2500, 2500], [5000, 5000], [5001, 20000]])
    stake_manager.set_is_stake_hub_active(True)
    stake_manager.set_tlp_rates()
    operators, consensuses = set_candidate
    turn_round()
    delegate_amount = 500000
    btc_value = 100
    delegate_coin_success(operators[0], accounts[0], delegate_amount)
    turn_round()
    delegate_btc_success(operators[1], accounts[0], btc_value, LOCK_SCRIPT)
    turn_round(consensuses, round_count=2)
    current_round = get_current_round()
    tx = stake_hub.onStakeChange(accounts[0])
    # Dual staking removed — dualStakingRate is always 0
    dual_staking_rate = 0
    assert tx.events['storedRewardBtcTx']['dualStakingRate'] == dual_staking_rate
    assert stake_hub.getDelegatorMap(accounts[0])[0] == current_round
    tracker0 = get_tracker(accounts[0])
    stake_hub_claim_reward(accounts[0])
    # CORE reward: COIN_REWARD * 2 (2 rounds of CORE on operators[0])
    # BTC reward: BTC_REWARD (1 round, full reward, no dual staking reduction)
    actual_reward = COIN_REWARD * 2 + BTC_REWARD
    assert tracker0.delta() == actual_reward
    turn_round(consensuses)
    stake_hub.calculateReward(accounts[0])
    stake_manager.set_lp_rates([[0, 20000]])
    stake_hub_claim_reward(accounts[0])
    assert tracker0.delta() == COIN_REWARD + BTC_REWARD
    turn_round(consensuses)


@pytest.mark.parametrize("onStakeChange", [True, False])
def test_calculateReward_invalid_after_operation(stake_hub, set_candidate, onStakeChange):
    stake_manager.set_lp_rates([[0, 1000], [2500, 2500], [5000, 5000], [5001, 20000]])
    stake_manager.set_is_stake_hub_active(True)
    stake_manager.set_tlp_rates()
    operators, consensuses = set_candidate
    turn_round()
    delegate_amount = 500000
    btc_value = 100
    delegate_coin_success(operators[0], accounts[0], delegate_amount)
    delegate_btc_success(operators[1], accounts[0], btc_value, LOCK_SCRIPT)
    turn_round(consensuses, round_count=2)
    if onStakeChange:
        stake_hub.onStakeChange(accounts[0])
        tx = stake_hub.onStakeChange(accounts[0])
    else:
        stake_hub.calculateReward(accounts[0], {'from': accounts[1]})
        tx = stake_hub.calculateReward(accounts[0], {'from': accounts[1]})
    assert len(tx.events) == 0


# calculateReward
def test_calculate_reward_only_btc_stakes(stake_hub, btc_agent, core_agent, set_candidate):
    operators, consensuses = set_candidate
    delegator = accounts[0]
    delegate_btc_success(operators[0], delegator, 100, LOCK_SCRIPT)
    turn_round()
    turn_round(consensuses)
    btc_agent.setIsActive(True)
    stake_manager.set_lp_rates([[0, 5000], [5000, 8000], [10000, 15000]])
    stake_manager.set_is_stake_hub_active(True)
    tx = stake_hub.calculateReward(delegator, {'from': accounts[1]})
    delegator_info = stake_hub.getDelegator(delegator)
    assert delegator_info[0] == get_current_round()
    assert len(delegator_info[1]) == 4
    assert delegator_info[1][2] == BTC_REWARD


def test_calculate_reward_only_core_stakes(stake_hub, btc_agent, core_agent, set_candidate):
    operators, consensuses = set_candidate
    delegator = accounts[0]
    delegate_coin_success(operators[0], delegator, 10000)
    turn_round()
    turn_round(consensuses, round_count=2)
    stake_manager.set_is_stake_hub_active(True)
    tx = stake_hub.calculateReward(delegator, {'from': accounts[1]})
    delegator_info = stake_hub.getDelegator(delegator)
    assert delegator_info[0] == get_current_round()
    assert len(delegator_info[1]) == 4
    assert delegator_info[1][0] == COIN_REWARD * 2


def test_calculate_reward_multiple_btc_and_core_stakes(stake_hub, btc_agent, core_agent, set_candidate):
    operators, consensuses = set_candidate
    delegator = accounts[0]
    delegate_coin_success(operators[2], delegator, 500000)
    delegate_coin_success(operators[2], delegator, 1000000)
    turn_round()
    delegate_btc_success(operators[0], delegator, 100, LOCK_SCRIPT)
    delegate_btc_success(operators[1], delegator, 100, LOCK_SCRIPT)
    turn_round()
    delegate_coin_success(operators[2], delegator, 800000)
    turn_round(consensuses)
    turn_round(consensuses)
    btc_agent.setIsActive(True)
    stake_manager.set_lp_rates([[0, 3000], [1, 4000], [5000, 6000], [8000, 10000], [15000, 20000]])
    stake_manager.set_is_stake_hub_active(True)

    tx = stake_hub.calculateReward(delegator, {'from': accounts[1]})
    # Dual staking removed — dualStakingRate is always 0
    for evt in tx.events['storedRewardBtcTx']:
        assert evt['dualStakingRate'] == 0
    delegator_info = stake_hub.getDelegator(delegator)
    assert abs(delegator_info[1][0] - COIN_REWARD * 2) <= 3
    # BTC: 2 validators * 2 rounds * BTC_REWARD (no dual staking multiplier)
    assert abs(delegator_info[1][2] - BTC_REWARD * 4) <= 3
    tracker0 = get_tracker(delegator)
    stake_hub_claim_reward(delegator)
    assert tracker0.delta() == sum(delegator_info[1])
    delegator_info = stake_hub.getDelegator(delegator)
    assert sum(delegator_info[1]) == 0


def test_calculate_reward_various_stake_combinations(stake_hub, btc_agent, core_agent, set_candidate):
    operators, consensuses = set_candidate
    delegator = accounts[0]
    delegate_btc_success(operators[0], delegator, 200, LOCK_SCRIPT)
    delegate_btc_success(operators[1], delegator, 100, LOCK_SCRIPT)

    delegate_coin_success(operators[2], delegator, 1000000)
    delegate_coin_success(operators[2], delegator, 500000)
    delegate_coin_success(operators[2], delegator, 800000)
    turn_round(consensuses, round_count=2)
    btc_agent.setIsActive(True)
    stake_manager.set_lp_rates([[0, 5000], [8000, 10000], [15000, 20000]])
    stake_manager.set_is_stake_hub_active(True)
    stake_hub.calculateReward(delegator, {'from': accounts[1]})
    stake_manager.set_lp_rates([[0, 30000]])
    delegator_info = stake_hub.getDelegator(delegator)
    assert abs(delegator_info[1][0] - COIN_REWARD) <= 2
    assert abs(delegator_info[1][2] - BTC_REWARD * 2) <= 2
    tracker0 = get_tracker(delegator)
    stake_hub_claim_reward(delegator)
    assert tracker0.delta() == sum(delegator_info[1])
    delegator_info = stake_hub.getDelegator(delegator)
    assert sum(delegator_info[1]) == 0
    turn_round(consensuses)
    stake_hub_claim_reward(delegator)
    # Next round: CORE from operators[2] + BTC from operators[0,1] with new LP rate 30000
    total_next = tracker0.delta()
    assert total_next > 0


def test_only_govhub_can_call(stake_hub):
    grades_encode = rlp.encode([])
    with brownie.reverts("the msg sender must be governance contract"):
        stake_hub.updateParam('grades', grades_encode)


@pytest.mark.parametrize("hard_cap", [
    [['coreHardcap', 2000], ['hashHardcap', 9000], ['btcHardcap', 10000]],
    [['coreHardcap', 1000], ['hashHardcap', 2000], ['btcHardcap', 8000]],
    [['coreHardcap', 100000], ['hashHardcap', 20000], ['btcHardcap', 30000]],
    [['coreHardcap', 10000], ['hashHardcap', 100000], ['btcHardcap', 30000]],
    [['coreHardcap', 10000], ['hashHardcap', 10000], ['btcHardcap', 100000]]
])
def test_update_hard_cap_success(stake_hub, hard_cap):
    update_system_contract_address(stake_hub, gov_hub=accounts[0])
    for h in hard_cap:
        hex_value = padding_left(Web3.to_hex(h[1]), 64)
        stake_hub.updateParam(h[0], hex_value)
    for i in range(3):
        assert stake_hub.assets(i)['hardcap'] == hard_cap[i][-1]


@pytest.mark.parametrize("hard_cap", [
    ['coreHardcap', 100001],
    ['hashHardcap', 100001],
    ['btcHardcap', 100001],
    ['btcHardcap', 200002],
])
def test_update_hard_cap_failed(stake_hub, hard_cap):
    update_system_contract_address(stake_hub, gov_hub=accounts[0])
    hex_value = padding_left(Web3.to_hex(hard_cap[1]), 64)
    with brownie.reverts(f"OutOfBounds: {hard_cap[0]}, {hard_cap[1]}, 1, 100000"):
        stake_hub.updateParam(hard_cap[0], hex_value)


def test_update_param_nonexistent_governance_param_reverts(stake_hub):
    update_system_contract_address(stake_hub, gov_hub=accounts[0])
    with brownie.reverts(f"UnsupportedGovParam: error"):
        hex_value = padding_left(Web3.to_hex(100), 64)
        stake_hub.updateParam('error', hex_value)


def test_stake_hup_add_round_reward(stake_hub, validator_set, candidate_hub, core_agent, btc_light_client, btc_stake):
    turn_round()
    register_candidate(operator=accounts[1])
    register_candidate(operator=accounts[2])

    # With hardcap ratio distribution: CORE=6000/15000=40%, HASH=2000/15000=13%, BTC=4000/15000=26%, ZEC=3000/15000=20%
    # For reward=100: CORE=40, HASH=13, BTC=26, ZEC=20
    # For reward=200: CORE=80, HASH=26, BTC=53, ZEC=40
    tests = [
        {'status': 'success', 'validators': [], 'reward_list': [], 'round': 100,
         'expect_round_reward': [OrderedDict([('round', 100), ('validator', ()), ('amount', ())]),
                                 OrderedDict([('round', 100), ('validator', ()), ('amount', ())]),
                                 OrderedDict([('round', 100), ('validator', ()), ('amount', ())]),
                                 OrderedDict([('round', 100), ('validator', ()), ('amount', ())])]},

        {'status': 'success', 'validators': [accounts[1]], 'reward_list': [100], 'round': 100,
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (40,))]),
                                 OrderedDict([('round', 100), ('amount', (13,))]),
                                 OrderedDict([('round', 100), ('amount', (26,))]),
                                 OrderedDict([('round', 100), ('amount', (20,))])]},

        {'status': 'success', 'validators': [accounts[1], accounts[2]], 'reward_list': [100, 200], 'round': 100,
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (40, 80))]),
                                 OrderedDict([('round', 100), ('amount', (13, 26))]),
                                 OrderedDict([('round', 100), ('amount', (26, 53))]),
                                 OrderedDict([('round', 100), ('amount', (20, 40))])]},

        {'status': 'success', 'validators': [accounts[1]], 'reward_list': [100], 'round': 100,
         'add_core': [(accounts[1], 100)],
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (40,))]),
                                 OrderedDict([('round', 100), ('amount', (13,))]),
                                 OrderedDict([('round', 100), ('amount', (26,))]),
                                 OrderedDict([('round', 100), ('amount', (20,))])]},

        {'status': 'success', 'validators': [accounts[1], accounts[2]], 'reward_list': [100, 100], 'round': 100,
         'add_core': [(accounts[1], 100), (accounts[2], 100)],
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (40, 40))]),
                                 OrderedDict([('round', 100), ('amount', (13, 13))]),
                                 OrderedDict([('round', 100), ('amount', (26, 26))]),
                                 OrderedDict([('round', 100), ('amount', (20, 20))])]},

        {'status': 'success', 'validators': [accounts[1]], 'reward_list': [100], 'round': 100,
         'add_core': [(accounts[1], 100)], 'add_pow': [(accounts[1], [accounts[0]])],
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (40,))]),
                                 OrderedDict([('round', 100), ('amount', (13,))]),
                                 OrderedDict([('round', 100), ('amount', (26,))]),
                                 OrderedDict([('round', 100), ('amount', (20,))])]},

        {'status': 'success', 'validators': [accounts[1], accounts[1]], 'reward_list': [100, 100], 'round': 100,
         'add_core': [(accounts[1], 100), (accounts[2], 100)], 'add_pow': [(accounts[1], [accounts[0]])],
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (40, 40))]),
                                 OrderedDict([('round', 100), ('amount', (13, 13))]),
                                 OrderedDict([('round', 100), ('amount', (26, 26))]),
                                 OrderedDict([('round', 100), ('amount', (20, 20))])]},

        {'status': 'success', 'validators': [accounts[1]], 'reward_list': [100], 'round': 100,
         'add_core': [(accounts[1], 100)], 'add_pow': [(accounts[1], [accounts[0]])],
         'add_btc': [(accounts[1], 1, 1, [])],
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (40,))]),
                                 OrderedDict([('round', 100), ('amount', (13,))]),
                                 OrderedDict([('round', 100), ('amount', (26,))]),
                                 OrderedDict([('round', 100), ('amount', (20,))])]},

        {'status': 'success', 'validators': [accounts[1], accounts[1]], 'reward_list': [100, 100], 'round': 100,
         'add_core': [(accounts[1], 100), (accounts[2], 100)], 'add_pow': [(accounts[1], [accounts[0]])],
         'add_btc': [(accounts[1], 1, 1, []), (accounts[2], 1, 1, [])],
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (40, 40))]),
                                 OrderedDict([('round', 100), ('amount', (13, 13))]),
                                 OrderedDict([('round', 100), ('amount', (26, 26))]),
                                 OrderedDict([('round', 100), ('amount', (20, 20))])]},

        {'status': 'success', 'validators': [accounts[1], accounts[1]], 'reward_list': [100, 100], 'round': 100,
         'add_core': [(accounts[1], 100), (accounts[2], 100)], 'add_pow': [(accounts[1], [accounts[0]])],
         'add_btc': [(accounts[1], 1, 1, []), (accounts[2], 1, 1, [])], 'unclaimed_reward': 10,
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (40, 40))]),
                                 OrderedDict([('round', 100), ('amount', (13, 13))]),
                                 OrderedDict([('round', 100), ('amount', (26, 26))]),
                                 OrderedDict([('round', 100), ('amount', (20, 20))])]},

        {'status': 'failed', 'err': 'the length of validators and rewardList should be equal',
         'validators': [accounts[1], accounts[2]], 'reward_list': [100], 'round': 100, 'expect_round_reward': []},
    ]

    for test in tests:
        print(f'case{tests.index(test)}:', test)
        value_sum = 0
        for v in test['reward_list']:
            value_sum += v
        if 'add_core' in test:
            for validator, v in test['add_core']:
                core_agent.setCandidateMapAmount(validator, v, v, 0)
        if 'add_pow' in test:
            for v1, v2 in test['add_pow']:
                btc_light_client.setMiners(test['round'] - 7, v1, v2)
        if 'add_btc' in test:
            for validator, v1, v2, arr in test['add_btc']:
                btc_stake.setCandidateMap(validator, v1, v2, arr)
        tx = candidate_hub.getScoreMock(test['validators'], test['round'])
        if test['status'] == 'success':
            tx = validator_set.addRoundRewardMock(test['validators'], test['reward_list'], test['round'],
                                                  {'from': accounts[0], 'value': value_sum})
            for i in range(len(test['expect_round_reward'])):
                expect_event(tx, 'roundReward', test['expect_round_reward'][i], i)
        else:
            with brownie.reverts(test['err']):
                validator_set.addRoundRewardMock(test['validators'], test['reward_list'], test['round'],
                                                 {'from': accounts[0], 'value': value_sum})


def test_stake_hup_get_hybrid_score(stake_hub, validator_set, candidate_hub, core_agent, btc_light_client, btc_stake):
    turn_round()
    register_candidate(operator=accounts[1])
    register_candidate(operator=accounts[2])

    tests = [
        {'status': 'success', 'validators': [], 'round': 100, 'expect_scores': ()},
        {'status': 'success', 'validators': [accounts[1]], 'round': 100, 'expect_scores': [(0, 0, 0, 0)]},
        {'status': 'success', 'validators': [accounts[1]], 'round': 100, 'add_core': [(accounts[1], 100)],
         'expect_scores': [(100, 100, 0, 0)]},
        {'status': 'success', 'validators': [accounts[1]], 'round': 100, 'add_core': [(accounts[1], 100)],
         'add_pow': [(accounts[1], [accounts[0]])], 'expect_scores': [(133, 100, 33, 0)]},
        {'status': 'success', 'validators': [accounts[1]], 'round': 100, 'add_core': [(accounts[1], 100)],
         'add_pow': [(accounts[1], [accounts[0]])], 'add_btc': [(accounts[1], 1, 1, [])],
         'expect_scores': [(199, 100, 33, 66)]},
        {'status': 'success', 'validators': [accounts[1], accounts[2]], 'round': 100,
         'add_core': [(accounts[1], 100), (accounts[2], 200)],
         'add_pow': [(accounts[1], [accounts[0]]), (accounts[2], [accounts[0]])],
         'add_btc': [(accounts[1], 1, 1, []), (accounts[2], 1, 1, [])],
         'expect_scores': [(250, 100, 50, 100), (350, 200, 50, 100)]}
    ]

    for test in tests:
        print(f'case{tests.index(test)}:', test)
        if 'add_core' in test:
            for validator, v in test['add_core']:
                core_agent.setCandidateMapAmount(validator, v, v, 0)
        if 'add_pow' in test:
            for v1, v2 in test['add_pow']:
                btc_light_client.setMiners(test['round'] - 7, v1, v2)
        if 'add_btc' in test:
            for validator, v1, v2, arr in test['add_btc']:
                btc_stake.setCandidateMap(validator, v1, v2, arr)
        if test['status'] == 'success':
            tx = candidate_hub.getScoreMock(test['validators'], test['round'])


@pytest.mark.parametrize('test', [
    {'add_core': 1000000, 'add_btc': 100, 'expect_rewards': (5418, 0, 3612, 0)},
    # Dual staking removed — BTC reward is full 3612 regardless of LP rates
    {'add_core': 10000, 'add_btc': 1, 'expect_rewards': (5418, 0, 3612, 0), 'is_active': True},
    {'add_core': 120000, 'add_btc': 10, 'expect_rewards': (5418, 0, 3612, 0), 'is_active': True},
    {'add_core': 5000000, 'add_btc': 1000, 'expect_rewards': (5418, 0, 3612, 0), 'is_active': True},
    {'add_core': 5000, 'add_btc': 10, 'expect_rewards': (5418, 0, 3612, 0), 'is_active': True}
])
def test_stake_hub_calculate_reward(stake_hub, btc_agent, candidate_hub, core_agent, btc_stake, set_candidate, test):
    operators, consensuses = set_candidate
    turn_round()
    delegate_coin_success(operators[1], accounts[1], test['add_core'])
    delegate_btc_success(operators[0], accounts[1], test['add_btc'], LOCK_SCRIPT, relay=accounts[1])
    turn_round(consensuses, round_count=2)
    graders_keys = [1000, 4000, 5000, 10000]
    graders_values = [5000, 7000, 8000, 10000]
    if test.get('is_active'):
        btc_agent.setIsActive(True)
        btc_agent.setInitLpRates(graders_keys, graders_values)
    actual = stake_hub.calculateRewardMock(accounts[1]).return_value
    expected = test['expect_rewards']
    for i in range(len(expected)):
        assert abs(actual[i] - expected[i]) <= 3, f"reward[{i}]: {actual[i]} != {expected[i]}"

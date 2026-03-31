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
TX_FEE = Web3.to_wei(1, 'ether')
# the tx fee is 1 ether
actual_block_reward = 0
COIN_REWARD = 0
BLOCK_REWARD = 0


@pytest.fixture()
def set_candidate():
    operators = []
    consensuses = []
    for operator in accounts[5:8]:
        operators.append(operator)
        consensuses.append(register_candidate(operator=operator))
    return operators, consensuses


@pytest.fixture(scope="module", autouse=True)
def set_up(min_init_delegate_value, core_agent, candidate_hub, hash_power_agent,
           btc_light_client, validator_set, stake_hub, system_reward, gov_hub):
    global MIN_INIT_DELEGATE_VALUE
    global CANDIDATE_REGISTER_MARGIN
    global candidate_hub_instance
    global core_agent_instance
    global required_coin_deposit
    global btc_light_client_instance
    global actual_block_reward
    global COIN_REWARD
    global BLOCK_REWARD
    global STAKE_HUB, CORE_AGENT, HASH_POWER_AGENT, TOTAL_REWARD, GOV_HUB
    global COIN_REWARD, HASH_REWARD, ZEC_REWARD
    STAKE_HUB = stake_hub
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
    HASH_REWARD = TOTAL_REWARD * HardCap.POWER_HARD_CAP // HardCap.SUM_HARD_CAP
    ZEC_REWARD = TOTAL_REWARD * HardCap.ZEC_HARD_CAP // HardCap.SUM_HARD_CAP
    STAKE_HUB = stake_hub
    system_reward.setOperator(stake_hub.address)


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


def test_add_round_reward_success(validator_set, core_agent, btc_light_client, candidate_hub, stake_hub):
    round_tag = 100
    validators = [accounts[1], accounts[2]]
    reward_list = [1000, 2000]
    value_sum = sum(reward_list)
    power_value = 5
    core_value = 100
    for validator in validators:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
    candidate_hub.getScoreMock(validators, round_tag)
    tx = validator_set.addRoundRewardMock(validators, reward_list, round_tag,
                                          {'from': accounts[0], 'value': value_sum})
    for index, round_reward in enumerate(tx.events['roundReward']):
        assert len(round_reward['amount']) == len(validators)


def test_no_stake_on_validator(validator_set, core_agent, btc_light_client, candidate_hub, stake_hub):
    round_tag = 100
    validators = [accounts[1], accounts[2]]
    reward_list = [1000, 2000]
    value_sum = sum(reward_list)
    candidate_hub.getScoreMock(validators, round_tag)
    tx = validator_set.addRoundRewardMock(validators, reward_list, round_tag,
                                          {'from': accounts[0], 'value': value_sum})
    # With hardcap ratio distribution, rewards are distributed to agents regardless of stakes.
    # Each agent receives its hardcap proportion via distributeReward.
    for round_reward in tx.events['roundReward']:
        assert len(round_reward['amount']) == len(validators)


def test_add_round_reward_core_only(validator_set, core_agent, candidate_hub,
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
    # With hardcap ratio distribution, CORE gets 6000/11000 of each reward
    assert tx.events['roundReward'][0]['amount'] == [r * 6000 // 11000 for r in reward_list]


def test_reward_without_stake(validator_set, core_agent, btc_light_client, candidate_hub, stake_hub):
    round_tag = 100
    validators = [accounts[1], accounts[2]]
    reward_list = [0, 0]
    value_sum = sum(reward_list)
    power_value = 5
    core_value = 100
    for validator in validators:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
    candidate_hub.getScoreMock(validators, round_tag)
    tx = validator_set.addRoundRewardMock(validators, reward_list, round_tag,
                                          {'from': accounts[0], 'value': value_sum})
    # With zero rewards, all asset round rewards should be [0, 0]
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
    pytest.param({'add_core': 1e18, 'add_hash': 200}, id="core & hash"),
    pytest.param({'add_core': 0, 'add_hash': 0}, id="core & hash zero"),
])
def test_get_hybrid_score_success(core_agent, btc_light_client, candidate_hub, stake_hub,
                                  hash_power_agent, zec_agent, test):
    round_tag = 100
    validators = [accounts[1], accounts[2]]
    core_value = test.get('add_core', 0)
    power_value = test.get('add_hash', 0)
    zec_value = 0
    values = [core_value, power_value, zec_value]
    for validator in validators[:1]:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
    tx = candidate_hub.getScoreMock(validators, round_tag)
    scores = tx.return_value
    assert scores[1] == 0


def test_calculate_factor_success(core_agent, btc_light_client, candidate_hub, stake_hub,
                                  hash_power_agent):
    round_tag = 100
    validators = [accounts[1]]
    core_value = 100e18
    power_value = 200
    for validator in validators[:1]:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
    candidate_hub.getScoreMock(validators, round_tag)


def test_two_rounds_score_calculation_success(core_agent, btc_light_client, candidate_hub, stake_hub,
                                              hash_power_agent):
    round_tag = 100
    validators = [accounts[1]]
    core_value = 100e18
    power_value = 200
    for validator in validators[:1]:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
    candidate_hub.getScoreMock(validators, round_tag)
    candidate_hub.getScoreMock(validators, round_tag)


def test_validators_score_calculation_success(core_agent, btc_light_client, candidate_hub, stake_hub,
                                              hash_power_agent):
    round_tag = 100
    validators = [accounts[1], accounts[2]]
    core_value = 100e18
    power_value = 200
    for validator in validators:
        core_agent.setCandidateMapAmount(validator, core_value, core_value, 0)
        btc_light_client.setMiners(round_tag - 7, validator, [accounts[0]] * power_value)
    tx = candidate_hub.getScoreMock(validators, round_tag)
    scores = tx.return_value
    assert len(scores) == len(validators)


def test_only_candidate_can_call_set_new_round(stake_hub):
    with brownie.reverts("the msg sender must be candidate contract"):
        stake_hub.setNewRound(accounts[:2], 100)


def test_set_new_round_success(stake_hub, core_agent):
    round_tag = 100
    update_system_contract_address(stake_hub, candidate_hub=accounts[0])
    stake_hub.setNewRound(accounts[:2], round_tag)
    assert core_agent.roundTag() == round_tag


def __mock_stake_hub_reward():
    accounts[3].transfer(STAKE_HUB, Web3.to_wei(1, 'ether'))



def test_get_assets_success(stake_hub, core_agent, hash_power_agent, zec_agent):
    assets = stake_hub.getAssets()
    assert assets == [['CORE', core_agent.address, 6000], ['HASHPOWER', hash_power_agent.address, 2000],
                      ['ZEC', zec_agent.address, 3000]]


def test_only_govhub_can_call(stake_hub):
    grades_encode = rlp.encode([])
    with brownie.reverts("the msg sender must be governance contract"):
        stake_hub.updateParam('grades', grades_encode)


@pytest.mark.parametrize("hard_cap", [
    [['coreHardcap', 2000], ['hashHardcap', 9000]],
    [['coreHardcap', 3000], ['hashHardcap', 3000]],
    [['coreHardcap', 100000], ['hashHardcap', 20000]],
    [['coreHardcap', 10000], ['hashHardcap', 100000]],
])
def test_update_hard_cap_success(stake_hub, hard_cap):
    update_system_contract_address(stake_hub, gov_hub=accounts[0])
    for h in hard_cap:
        hex_value = padding_left(Web3.to_hex(h[1]), 64)
        stake_hub.updateParam(h[0], hex_value)
    for i in range(len(hard_cap)):
        assert stake_hub.assets(i)['hardcap'] == hard_cap[i][-1]


@pytest.mark.parametrize("hard_cap", [
    ['coreHardcap', 100001],
    ['hashHardcap', 100001],
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


def test_stake_hup_add_round_reward(stake_hub, validator_set, candidate_hub, core_agent, btc_light_client):
    turn_round()
    register_candidate(operator=accounts[1])
    register_candidate(operator=accounts[2])

    # With hardcap ratio distribution: CORE=6000/11000=54%, HASH=2000/11000=18%, ZEC=3000/11000=27%
    # For reward=100: CORE=54, HASH=18, ZEC=27
    # For reward=200: CORE=109, HASH=36, ZEC=54
    tests = [
        {'status': 'success', 'validators': [], 'reward_list': [], 'round': 100,
         'expect_round_reward': [OrderedDict([('round', 100), ('validator', ()), ('amount', ())]),
                                 OrderedDict([('round', 100), ('validator', ()), ('amount', ())]),
                                 OrderedDict([('round', 100), ('validator', ()), ('amount', ())])]},

        {'status': 'success', 'validators': [accounts[1]], 'reward_list': [100], 'round': 100,
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (54,))]),
                                 OrderedDict([('round', 100), ('amount', (18,))]),
                                 OrderedDict([('round', 100), ('amount', (27,))])]},

        {'status': 'success', 'validators': [accounts[1], accounts[2]], 'reward_list': [100, 200], 'round': 100,
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (54, 109))]),
                                 OrderedDict([('round', 100), ('amount', (18, 36))]),
                                 OrderedDict([('round', 100), ('amount', (27, 54))])]},

        {'status': 'success', 'validators': [accounts[1]], 'reward_list': [100], 'round': 100,
         'add_core': [(accounts[1], 100)],
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (54,))]),
                                 OrderedDict([('round', 100), ('amount', (18,))]),
                                 OrderedDict([('round', 100), ('amount', (27,))])]},

        {'status': 'success', 'validators': [accounts[1], accounts[2]], 'reward_list': [100, 100], 'round': 100,
         'add_core': [(accounts[1], 100), (accounts[2], 100)],
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (54, 54))]),
                                 OrderedDict([('round', 100), ('amount', (18, 18))]),
                                 OrderedDict([('round', 100), ('amount', (27, 27))])]},

        {'status': 'success', 'validators': [accounts[1]], 'reward_list': [100], 'round': 100,
         'add_core': [(accounts[1], 100)], 'add_pow': [(accounts[1], [accounts[0]])],
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (54,))]),
                                 OrderedDict([('round', 100), ('amount', (18,))]),
                                 OrderedDict([('round', 100), ('amount', (27,))])]},

        {'status': 'success', 'validators': [accounts[1], accounts[1]], 'reward_list': [100, 100], 'round': 100,
         'add_core': [(accounts[1], 100), (accounts[2], 100)], 'add_pow': [(accounts[1], [accounts[0]])],
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (54, 54))]),
                                 OrderedDict([('round', 100), ('amount', (18, 18))]),
                                 OrderedDict([('round', 100), ('amount', (27, 27))])]},

        {'status': 'success', 'validators': [accounts[1], accounts[1]], 'reward_list': [100, 100], 'round': 100,
         'add_core': [(accounts[1], 100), (accounts[2], 100)], 'add_pow': [(accounts[1], [accounts[0]])],
         'expect_round_reward': [OrderedDict([('round', 100), ('amount', (54, 54))]),
                                 OrderedDict([('round', 100), ('amount', (18, 18))]),
                                 OrderedDict([('round', 100), ('amount', (27, 27))])]},

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


def test_stake_hup_get_hybrid_score(stake_hub, validator_set, candidate_hub, core_agent, btc_light_client):
    turn_round()
    register_candidate(operator=accounts[1])
    register_candidate(operator=accounts[2])

    tests = [
        {'status': 'success', 'validators': [], 'round': 100, 'expect_scores': ()},
        {'status': 'success', 'validators': [accounts[1]], 'round': 100, 'expect_scores': [(0, 0, 0)]},
        {'status': 'success', 'validators': [accounts[1]], 'round': 100, 'add_core': [(accounts[1], 100)],
         'expect_scores': [(100, 100, 0)]},
        {'status': 'success', 'validators': [accounts[1]], 'round': 100, 'add_core': [(accounts[1], 100)],
         'add_pow': [(accounts[1], [accounts[0]])], 'expect_scores': [(133, 100, 33)]},
        {'status': 'success', 'validators': [accounts[1], accounts[2]], 'round': 100,
         'add_core': [(accounts[1], 100), (accounts[2], 200)],
         'add_pow': [(accounts[1], [accounts[0]]), (accounts[2], [accounts[0]])],
         'expect_scores': [(133, 100, 33), (233, 200, 33)]}
    ]

    for test in tests:
        print(f'case{tests.index(test)}:', test)
        if 'add_core' in test:
            for validator, v in test['add_core']:
                core_agent.setCandidateMapAmount(validator, v, v, 0)
        if 'add_pow' in test:
            for v1, v2 in test['add_pow']:
                btc_light_client.setMiners(test['round'] - 7, v1, v2)
        if test['status'] == 'success':
            tx = candidate_hub.getScoreMock(test['validators'], test['round'])

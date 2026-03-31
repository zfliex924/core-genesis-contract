from typing import Dict
from brownie.test import strategy
from .common import turn_round, register_candidate, stake_hub_claim_reward
from .delegate import *
from .utils import *

TX_FEE = int(1e4)


def set_relayer_register(relay_hub):
    for account in accounts[:3]:
        relay_hub.setRelayerRegister(account.address, True)


class Status:
    REGISTER = 1 << 0
    UNREGISTER = 1 << 2
    VALIDATOR = 1 << 3
    REFUSED = 1 << 4


class Agent:
    def __init__(self, margin):
        self.delegators = {}
        self.status = Status.REGISTER
        self.total_power = 0
        self.total_coin = 0
        self.agent_score = 0
        self.score = 0
        self.margin = margin
        self.reward = {
            'coin_reward': 0,
            'power_reward': 0,
        }
        self.coin_reward = []
        self.power_reward = []

    def clear_score(self):
        self.agent_score = 0


class Validator:
    def __init__(self, operator, consensus, fee, commission):
        self.operator_address = operator
        self.consensus_address = consensus
        self.fee_address = fee
        self.commission = commission
        self.income = 0


class Delegator:
    def __init__(self):
        self.delegator = None

    def add_delegator(self, delegator):
        self.delegator = delegator

    def delegate_power(self, candidate, value=1, stake_round=0):
        delegate_power_success(candidate, self.delegator, value, stake_round)

    def delegate_coin(self, candidate, amount):
        tx = delegate_coin_success(candidate, self.delegator, amount)
        return tx

    def undelegate_coin(self, candidate, amount):
        undelegate_coin_success(candidate, self.delegator, amount)

    def transfer_coin(self, source_agent, target_agent, amount):
        transfer_coin_success(source_agent, target_agent, self.delegator, amount)


N = 0


class StateMachine:
    core_amount = strategy('uint', min_value="10 ether", max_value="10000 ether")
    hash_value = strategy('uint', min_value=1, max_value=100)
    is_turn_round = strategy('bool')
    operate_count = strategy('uint', min_value=10, max_value=20)

    def __init__(self, candidate_hub, validator_set, zec_light_client, slash_indicator,
                 stake_hub, core_agent, relay_hub, gov_hub):
        self.candidate_hub = candidate_hub
        self.validator_set = validator_set
        self.zec_light_client = zec_light_client
        self.slash_indicator = slash_indicator
        self.stake_hub = stake_hub
        self.relay_hub = relay_hub
        self.core_agent = core_agent
        self.gov_hub = gov_hub
        self.min_init_delegate_value = 100 * 100
        self.power_value = 20
        self.candidate_margin = self.candidate_hub.requiredMargin()
        accounts[99].transfer(self.validator_set.address, Web3.to_wei(100000, 'ether'))
        self.operators = []
        for operator in accounts[60:90]:
            register_candidate(consensus=operator, fee_address=operator, operator=operator,
                               margin=self.candidate_margin)
            self.operators.append(operator)

    def setup(self):
        global N
        N += 1
        print(f"Scenario {N}")
        random.seed(time.time_ns())
        self.delegate = {}
        self.candidate_hub.setControlRoundTimeTag(True)
        self.zec_light_client.setCheckResult(True, 0)
        self.candidate_hub.setRoundTag(7)
        self.candidate_hub.setValidatorCount(21)
        old_turn_round()

    def initialize(self, core_amount, hash_value, is_turn_round, operate_count):
        print('Generate old data')
        self.__random_old_delegate(core_amount, hash_value, operate_count)
        self.__random_old_undelegate_and_transfer(operate_count)
        self.stake_hub.initHybridScoreMock()
        if is_turn_round:
            turn_round(self.operators)
        print(f"{'@' * 48} initialize end {'@' * 48}")

    def invariant(self):
        print('invariant>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')

    def rule_delegate_coin(self, core_amount):
        candidates = self.candidate_hub.getCanDelegateCandidates()
        if not candidates:
            return
        agent = random.choice(candidates)
        delegator = random.choice(accounts[:-1])
        self.__add_delegate(delegator)
        value = core_amount
        self.delegate[delegator].delegate_coin(agent, value)
        print('rule_delegate_coin>>>>')

    def rule_undelegate_coin(self):
        delegator = random.choice(accounts[:-1])
        candidates = self.core_agent.getCandidateListByDelegator(delegator)
        if len(candidates) == 0:
            return
        agent = random.choice(candidates)
        realtime_amount = self.core_agent.getDelegator(agent, delegator)['realtimeAmount']
        if realtime_amount > 0:
            undelegate_coin_success(agent, delegator, realtime_amount)
            print('rule_undelegate_coin>>>>')

    def rule_transfer_coin(self):
        delegator = random.choice(accounts[:-1])
        candidates = self.core_agent.getCandidateListByDelegator(delegator)
        if len(candidates) == 0:
            return
        agent = random.choice(candidates)
        target_agent = random.choice(self.operators)

        realtime_amount = self.core_agent.getDelegator(agent, delegator)['realtimeAmount']
        if realtime_amount > 0:
            transfer_coin_success(agent, target_agent, delegator, realtime_amount)
            print('rule_transfer_coin>>>>')

    def rule_old_delegate_coin(self, core_amount):
        candidates = self.candidate_hub.getCanDelegateCandidates()
        if not candidates:
            return
        agent = random.choice(candidates)
        delegator = random.choice(accounts[:-1])
        self.__add_delegate(delegator)
        value = core_amount
        old_delegate_coin_success(agent, delegator, value, False)
        print('rule_delegate_coin>>>>')

    def rule_old_undelegate_coin(self):
        delegator = random.choice(accounts[:-1])
        candidates = self.core_agent.getCandidateListByDelegator(delegator)
        if len(candidates) == 0:
            return
        agent = random.choice(candidates)
        realtime_amount = self.core_agent.getDelegator(agent, delegator)['realtimeAmount']
        if realtime_amount > 100:
            old_undelegate_coin_success(agent, delegator, realtime_amount, False)
            print('rule_old_undelegate_coin success')

    def rule_old_transfer_coin(self):
        delegator = random.choice(accounts[:-1])
        candidates = self.core_agent.getCandidateListByDelegator(delegator)
        if len(candidates) == 0:
            return
        agent = random.choice(candidates)
        target_agent = random.choice(self.operators)

        realtime_amount = self.core_agent.getDelegator(agent, delegator)['realtimeAmount']
        if realtime_amount > 100:
            old_transfer_coin_success(agent, target_agent, delegator, realtime_amount, False)
            print('rule_old_transfer_coin success')

    def rule_delegate_power(self, hash_value):
        candidates = self.candidate_hub.getCanDelegateCandidates()
        if not candidates:
            return
        agent = random.choice(candidates)
        delegator = random.choice(accounts[:-1])
        self.__add_delegate(delegator)
        value = hash_value
        self.delegate[delegator].delegate_power(agent, value)

    def rule_claim_reward(self):
        delegator = list(self.delegate.keys())
        if len(delegator) < 1:
            return
        delegate = random.choice(delegator)
        stake_hub_claim_reward(delegate)

    def rule_turn_round(self, core_amount, hash_value, operate_count, is_turn_round):
        if is_turn_round:
            valid_candidates = self.candidate_hub.getCanDelegateCandidates()
            turn_round(valid_candidates)
        self.__random_new_delegate(core_amount, hash_value, operate_count)
        valid_candidates = self.candidate_hub.getCanDelegateCandidates()
        turn_round(valid_candidates)

    def teardown(self):
        print(f"{'@' * 51} teardown {'@' * 51}")
        valid_candidates = self.candidate_hub.getCanDelegateCandidates()
        turn_round(valid_candidates)

    def __add_delegate(self, address):
        if address not in self.delegate:
            delegate = Delegator()
            delegate.add_delegator(address)
            self.delegate[address] = delegate

    def __random_old_delegate(self, core_amount, hash_value, operate_count):
        old_operate = ['power', 'core']
        self.delegate_map = {
            'coin': {},
            'power': {},
        }
        agents_map = {}
        time.sleep(3)
        for i in range(operate_count):
            delegator = random.choice(accounts[:-6])
            operator = random.choice(self.operators)
            if agents_map.get(operator) is None:
                agents_map[operator] = {
                    'coin': 0,
                    'power': 0,
                }
            op = random.choice(old_operate)
            if op == 'power':
                if self.delegate_map['power'].get(delegator) is None:
                    self.delegate_map['power'][delegator] = 0
                delegate_power_success(operator, delegator, hash_value)
                self.delegate_map['power'][delegator] += hash_value
                agents_map[operator]['power'] += hash_value

            else:
                if self.delegate_map['coin'].get(delegator) is None:
                    self.delegate_map['coin'][delegator] = 0
                old_delegate_coin_success(operator, delegator, core_amount)
                self.delegate_map['coin'][delegator] += core_amount
                agents_map[operator]['coin'] += core_amount
        print('delegate_map>>>>>>>>>>>>>>>>>', self.delegate_map)
        print('agents_map>>>>>>>>>>>>>>>>>', agents_map)

    def __random_old_undelegate_and_transfer(self, operate_count):
        old_operate = ['undelegate', 'transfer']
        time.sleep(3)
        for i in range(operate_count):
            op = random.choice(old_operate)
            operator = random.choice(self.operators)
            delegator = random.choice(list(self.delegate_map['coin'].keys()))
            if op == 'undelegate':
                if self.core_agent.getDelegator(operator, delegator)['realtimeAmount'] > 0:
                    tx = old_undelegate_coin_success(operator, delegator, 0)
                    print('old_undelegate_coin_success>>>>>>>>>>', tx.events)
            else:
                operator1 = random.choice(self.operators)
                if self.core_agent.getDelegator(operator, delegator)['realtimeAmount'] > 0:
                    if operator1 != operator:
                        tx = old_transfer_coin_success(operator, operator1, delegator, 0)
                        print('old_transfer_coin_success>>>>>>>>>>', tx.events)

    def __random_new_delegate(self, core_amount, hash_value, operate_count):
        new_operate = ['power', 'core']
        delegate_map = {
            'coin': {},
            'power': {},
        }
        agents_map = {}
        for i in range(operate_count):
            delegator = random.choice(accounts[:-6])
            operator = random.choice(self.operators)
            if agents_map.get(operator) is None:
                agents_map[operator] = {
                    'coin': 0,
                    'power': 0,
                }
            op = random.choice(new_operate)
            if op == 'power':
                if delegate_map['power'].get(delegator) is None:
                    delegate_map['power'][delegator] = 0
                delegate_power_success(operator, delegator, hash_value)
                delegate_map['power'][delegator] += hash_value
                agents_map[operator]['power'] += hash_value

            else:
                if delegate_map['coin'].get(delegator) is None:
                    delegate_map['coin'][delegator] = 0
                delegate_coin_success(operator, delegator, core_amount)
                delegate_map['coin'][delegator] += core_amount
                agents_map[operator]['coin'] += core_amount


def test_stateful(state_machine, candidate_hub, validator_set, zec_light_client, slash_indicator,
                  stake_hub, core_agent, relay_hub, gov_hub):
    state_machine(
        StateMachine,
        candidate_hub,
        validator_set,
        zec_light_client,
        slash_indicator,
        stake_hub,
        core_agent,
        relay_hub,
        gov_hub,
        settings={"max_examples": 200, "stateful_step_count": 30}
    )

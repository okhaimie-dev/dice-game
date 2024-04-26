use starknet::ContractAddress;

#[starknet::interface]
pub trait IERC<TContractState> {
    fn transfer(ref self: TContractState, recipent: ContractAddress, amount: u8) -> bool;
}

#[starknet::interface]
pub trait IDiceGame<TContractState> {
    fn guess(ref self: TContractState, guess: felt252);
    fn process_randomness(ref self: TContractState);
    fn claim_prize(ref self: TContractState) -> bool;
}

#[starknet::contract]
mod DiceGame {
    use starknet::{
        ContractAddress, contract_address_const, get_block_number, get_caller_address, get_contract_address
    };
    use pragma_lib::abi::{IRandomnessDispatcher, IRandomnessDispatcherTrait};
    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait, IERC20Dispatcher};
    use openzeppelin::access::ownable::OwnableComponent;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl InternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        user_guesses: LegacyMap<ContractAddress, felt252>,
        user_balances: LegacyMap<ContractAddress, u256>,
        randomness_contract_address: ContractAddress,
        min_block_number_storage: u64,
        last_random_storage: felt252,
        token_contract: ContractAddress,
        winner: ContractAddress,
        erc20_token: IERC20Dispatcher,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event
    }

    #[constructor]
    fn constructor(ref self: ContractState, randomness_contract_address: ContractAddress, owner: ContractAddress, erc20_token: ContractAddress) {
        self.ownable.initializer(owner);
        self.erc20_token.write(IERC20Dispatcher { contract_address: erc20_token });
        self.randomness_contract_address.write(randomness_contract_address);
    }

    #[generate_trait]
    impl PragmaOracle of PragmaOracleTrait {
        fn get_last_random_number(self: @ContractState) -> felt252 {
            let last_random = self.last_random_storage.read();
            last_random
        }

        fn request_randomness_from_pragma(
            ref self: ContractState,
            seed: u64,
            callback_address: ContractAddress,
            callback_fee_limit: u128,
            publish_delay: u64,
            num_words: u64,
            calldata: Array<felt252>
        ) {
            let randomness_contract_address = self.randomness_contract_address.read();
            let randomness_dispatcher = IRandomnessDispatcher {
                contract_address: randomness_contract_address
            };

            // Approve the randomness contract to transfer the callback fee
            // You would need to send some ETH to this contract first to cover the fees
            let eth_dispatcher = ERC20ABIDispatcher {
                contract_address: contract_address_const::<
                    0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                >() // ETH Contract Address
            };
            eth_dispatcher
                .approve(
                    randomness_contract_address,
                    (callback_fee_limit + callback_fee_limit / 5).into()
                );

            // Request the randomness
            randomness_dispatcher
                .request_random(
                    seed, callback_address, callback_fee_limit, publish_delay, num_words, calldata
                );

            let current_block_number = get_block_number();
            self.min_block_number_storage.write(current_block_number + publish_delay);
        }

        fn receive_random_words(
            ref self: ContractState,
            requester_address: ContractAddress,
            request_id: u64,
            random_words: Span<felt252>,
            calldata: Array<felt252>
        ) {
            // Have to make sure that the caller is the Pragma Randomness Oracle contract
            let caller_address = get_caller_address();
            assert(
                caller_address == self.randomness_contract_address.read(),
                'caller not randomness contract'
            );
            // and that the current block is within publish_delay of the request block
            let current_block_number = get_block_number();
            let min_block_number = self.min_block_number_storage.read();
            assert(min_block_number <= current_block_number, 'block number issue');

            let random_word = *random_words.at(0);
            self.last_random_storage.write(random_word);
        }

        fn withdraw_extra_fee_fund(ref self: ContractState, receiver: ContractAddress) {
            self.ownable.assert_only_owner();
            let eth_dispatcher = ERC20ABIDispatcher {
                contract_address: contract_address_const::<
                    0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                >() // ETH Contract Address            
            };
            let balance = eth_dispatcher.balance_of(get_contract_address());
            eth_dispatcher.transfer(receiver, balance);
        }
    }

    #[abi(embed_v0)]
    impl DiceGame of super::IDiceGame<ContractState> {
        fn guess(ref self: ContractState, guess: felt252) {
            assert!(guess >= 1 && guess <=6, "Invalid guess");

            let caller = get_caller_address();
            self.user_guesses.write(caller, guess);
        }

        fn process_randomness(ref self: ContractState) {
            let caller = get_caller_address();
            let user_guess = self.user_guesses.read(caller);

            if user_guess == self.last_random_storage.read() {
                // Mint and transfer one token to the user
                self.erc20_token.read().transfer(caller, 1);
                self.user_balances.write(caller, self.user_balances.read(caller) + 1);
            }
        }

        fn claim_prize(ref self: ContractState) -> bool {
            // TODO
            true
        }

        
    }
}
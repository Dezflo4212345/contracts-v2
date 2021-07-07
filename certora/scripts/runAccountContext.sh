certoraRun contracts/mocks/certora/GetterSetterHarness.sol \
 	--verify GetterSetterHarness:certora/accountContext/SetAccountContext.spec \
 	--solc solc7.6 \
	--optimistic_loop \
 	--loop_iter 1 \
	--settings -smt_bitVectorTheory=true,-smt_hashingScheme=plainInjectivity \
	--packages_path '/c/Users/nurit/.brownie/packages' \
	--packages @openzeppelin=/c/Users/nurit/.brownie/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=/c/Users/nurit/.brownie/packages/compound-finance \
 	--solc_args "['--optimize', '--optimize-runs', '200']"  --staging alex/bv-solver-strategy --msg "AccountContext - all rules bv branch"
	 
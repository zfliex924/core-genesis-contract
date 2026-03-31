name="$1"
if [ ! -z "$name" ]; then
	echo "$name"
	solc @openzeppelin/=$(pwd)/node_modules/@openzeppelin/ --optimize --overwrite --abi -o ./abi contracts/${name}.sol
else
  contracts=( "BtcLightClient" "CandidateHub" "Foundation" "GovHub" \
    "RelayerHub" "SlashIndicator" "SystemReward" "ValidatorSet" \
    "HashPowerAgent" "NativeAgent" \
    "StakeHub" "Channel" "Configuration")

  for e in ${contracts[@]}
  do
    echo "$e"
    solc @openzeppelin/=$(pwd)/node_modules/@openzeppelin/ --optimize --overwrite --abi -o ./abi contracts/${e}.sol
  done
fi
#~/Downloads/solc-macos --bin -o ./TC_$name contracts/$name.sol

#abigen --bin=./$name/$name.bin --abi=./$name/$name.abi --pkg=$name --out=./$name/$name.go


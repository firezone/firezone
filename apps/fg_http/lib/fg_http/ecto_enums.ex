import EctoEnum

# We only allow dropping or accepting packets for now
defenum(RuleActionEnum, :action, [:block, :allow])

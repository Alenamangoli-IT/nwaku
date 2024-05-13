{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, os, osproc, streams, strutils, tempfiles],
  stew/[results],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  chronicles,
  stint,
  web3,
  json,
  libp2p/crypto/crypto,
  eth/keys

import
  ../../../waku/waku_rln_relay/protocol_types,
  ../../../waku/waku_rln_relay/constants,
  ../../../waku/waku_rln_relay/contract,
  ../../../waku/waku_rln_relay/rln,
  ../../../waku/waku_rln_relay/conversion_utils,
  ../../../waku/waku_rln_relay/group_manager/on_chain/group_manager,
  ../testlib/common

proc deployContract*(
    web3: Web3, code: string, gasPrice = 0, contractInput = ""
): Future[ReceiptObject] {.async.} =
  # the contract input is the encoded version of contract constructor's input
  # use nim-web3/encoding.nim module to find the appropriate encoding procedure for different argument types
  # e.g., consider the following contract constructor in solidity
  # 	constructor(uint256 x, uint256 y) 
  #
  # the contractInput can be calculated as follows
  # let
  #   x = 1.u256
  #   y = 5.u256
  # contractInput = encode(x).data  &  encode(y).data 
  # Note that the order of encoded inputs should match the order of the constructor inputs
  let provider = web3.provider
  let accounts = await provider.eth_accounts()

  var code = code
  if code[1] notin {'x', 'X'}:
    code = "0x" & code
  var tr: EthSend
  tr.source = web3.defaultAccount
  tr.data = code & contractInput
  tr.gas = Quantity(3000000000000).some
  if gasPrice != 0:
    tr.gasPrice = some(gasPrice)

  let r = await web3.send(tr)
  return await web3.getMinedTransactionReceipt(r)

proc ethToWei*(eth: UInt256): UInt256 =
  eth * 1000000000000000000.u256

proc generateCredentials*(rlnInstance: ptr RLN): IdentityCredential =
  let credRes = membershipKeyGen(rlnInstance)
  return credRes.get()

when defined(rln_v2):
  proc getRateCommitment*(
      idCredential: IdentityCredential, userMessageLimit: UserMessageLimit
  ): RateCommitment =
    return RateCommitment(
      idCommitment: idCredential.idCommitment, userMessageLimit: userMessageLimit
    )

proc generateCredentials*(rlnInstance: ptr RLN, n: int): seq[IdentityCredential] =
  var credentials: seq[IdentityCredential]
  for i in 0 ..< n:
    credentials.add(generateCredentials(rlnInstance))
  return credentials

#  a util function used for testing purposes
#  it deploys membership contract on Anvil (or any Eth client available on EthClient address)
#  must be edited if used for a different contract than membership contract
# <the difference between this and rln-v1 is that there is no need to deploy the poseidon hasher contract>
proc uploadRLNContract*(ethClientAddress: string): Future[Address] {.async.} =
  let web3 = await newWeb3(ethClientAddress)
  debug "web3 connected to", ethClientAddress

  # fetch the list of registered accounts
  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[1]
  let add = web3.defaultAccount
  debug "contract deployer account address ", add

  let balance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
  debug "Initial account balance: ", balance

  when defined(rln_v2):
    # deploy registry contract with its constructor inputs
    let receipt = await web3.deployContract(RegistryContractCode)
  else:
    # deploy the poseidon hash contract and gets its address
    let
      hasherReceipt = await web3.deployContract(PoseidonHasherCode)
      hasherAddress = hasherReceipt.contractAddress.get
    debug "hasher address: ", hasherAddress

    # encode registry contract inputs to 32 bytes zero-padded
    let
      hasherAddressEncoded = encode(hasherAddress).data
      # this is the contract constructor input
      contractInput = hasherAddressEncoded

    debug "encoded hasher address: ", hasherAddressEncoded
    debug "encoded contract input:", contractInput

    # deploy registry contract with its constructor inputs
    let receipt =
      await web3.deployContract(RegistryContractCode, contractInput = contractInput)

  let contractAddress = receipt.contractAddress.get()

  debug "Address of the deployed registry contract: ", contractAddress

  let registryContract = web3.contractSender(WakuRlnRegistry, contractAddress)
  when defined(rln_v2):
    let initReceipt = await registryContract.initialize().send()
    let newStorageReceipt = await registryContract.newStorage(20.u256).send()
  else:
    let newStorageReceipt = await registryContract.newStorage().send()

  debug "Receipt of the newStorage transaction: ", newStorageReceipt
  let newBalance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
  debug "Account balance after the contract deployment: ", newBalance

  await web3.close()
  debug "disconnected from ", ethClientAddress

  return contractAddress

proc createEthAccount*(): Future[(keys.PrivateKey, Address)] {.async.} =
  let web3 = await newWeb3(EthClient)
  let accounts = await web3.provider.eth_accounts()
  let gasPrice = int(await web3.provider.eth_gasPrice())
  web3.defaultAccount = accounts[0]

  let pk = keys.PrivateKey.random(rng[])
  let acc = Address(toCanonicalAddress(pk.toPublicKey()))

  var tx: EthSend
  tx.source = accounts[0]
  tx.value = some(ethToWei(10.u256))
  tx.to = some(acc)
  tx.gasPrice = some(gasPrice)

  # Send 10 eth to acc
  discard await web3.send(tx)
  let balance = await web3.provider.eth_getBalance(acc, "latest")
  assert(balance == ethToWei(10.u256))

  return (pk, acc)

proc getAnvilPath*(): string =
  var anvilPath = ""
  if existsEnv("XDG_CONFIG_HOME"):
    anvilPath = joinPath(anvilPath, os.getEnv("XDG_CONFIG_HOME", ""))
  else:
    anvilPath = joinPath(anvilPath, os.getEnv("HOME", ""))
  anvilPath = joinPath(anvilPath, ".foundry/bin/anvil")
  return $anvilPath

# Runs Anvil daemon
proc runAnvil*(port: int = 8540, chainId: string = "1337"): Process =
  # Passed options are
  # --port                            Port to listen on.
  # --gas-limit                       Sets the block gas limit in WEI.
  # --balance                         The default account balance, specified in ether.
  # --chain-id                        Chain ID of the network.
  # See anvil documentation https://book.getfoundry.sh/reference/anvil/ for more details
  try:
    let anvilPath = getAnvilPath()
    debug "Anvil path", anvilPath
    let runAnvil = startProcess(
      anvilPath,
      args = [
        "--port",
        $port,
        "--gas-limit",
        "300000000000000",
        "--balance",
        "10000",
        "--chain-id",
        chainId,
      ],
      options = {poUsePath},
    )
    let anvilPID = runAnvil.processID

    # We read stdout from Anvil to see when daemon is ready
    var anvilStartLog: string
    var cmdline: string
    while true:
      try:
        if runAnvil.outputstream.readLine(cmdline):
          anvilStartLog.add(cmdline)
          if cmdline.contains("Listening on 127.0.0.1:" & $port):
            break
      except Exception, CatchableError:
        break
    debug "Anvil daemon is running and ready", pid = anvilPID, startLog = anvilStartLog
    return runAnvil
  except: # TODO: Fix "BareExcept" warning
    error "Anvil daemon run failed", err = getCurrentExceptionMsg()

# Stops Anvil daemon
proc stopAnvil*(runAnvil: Process) {.used.} =
  let anvilPID = runAnvil.processID
  # We wait the daemon to exit
  try:
    # We terminate Anvil daemon by sending a SIGTERM signal to the runAnvil PID to trigger RPC server termination and clean-up
    kill(runAnvil)
    debug "Sent SIGTERM to Anvil", anvilPID = anvilPID
  except:
    error "Anvil daemon termination failed: ", err = getCurrentExceptionMsg()

proc setup*(): Future[OnchainGroupManager] {.async.} =
  let rlnInstanceRes =
    createRlnInstance(tree_path = genTempPath("rln_tree", "group_manager_onchain"))
  require:
    rlnInstanceRes.isOk()

  let rlnInstance = rlnInstanceRes.get()

  let contractAddress = await uploadRLNContract(EthClient)
  # connect to the eth client
  let web3 = await newWeb3(EthClient)

  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[0]

  var pk = none(string)
  let (privateKey, _) = await createEthAccount()
  pk = some($privateKey)

  let manager = OnchainGroupManager(
    ethClientUrl: EthClient,
    ethContractAddress: $contractAddress,
    ethPrivateKey: pk,
    rlnInstance: rlnInstance,
  )

  return manager

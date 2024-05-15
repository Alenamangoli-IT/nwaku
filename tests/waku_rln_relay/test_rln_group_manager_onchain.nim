{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, sequtils, deques, strutils],
  stew/[results, byteutils],
  testutils/unittests,
  chronos,
  chronicles,
  stint,
  web3,
  libp2p/crypto/crypto,
  eth/keys

import
  ../../../waku/waku_rln_relay/protocol_types,
  ../../../waku/waku_rln_relay/constants,
  ../../../waku/waku_rln_relay/rln,
  ../../../waku/waku_rln_relay/conversion_utils,
  ../../../waku/waku_rln_relay/group_manager/on_chain/group_manager,
  ./utils_onchain

suite "Onchain group manager":
  # We run Anvil
  let runAnvil {.used.} = runAnvil()

  asyncTest "should initialize successfully":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error

    check:
      manager.ethRpc.isSome()
      manager.rlnContract.isSome()
      manager.membershipFee.isSome()
      manager.initialized
      manager.rlnContractDeployedBlockNumber > 0

    await manager.stop()

  asyncTest "should error on initialization when loaded metadata does not match":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error

    let metadataSetRes = manager.setMetadata()
    assert metadataSetRes.isOk(), metadataSetRes.error
    let metadataOpt = manager.rlnInstance.getMetadata().valueOr:
      raiseAssert $error
    assert metadataOpt.isSome(), "metadata is not set"
    let metadata = metadataOpt.get()

    assert metadata.chainId == 1337, "chainId is not equal to 1337"
    assert metadata.contractAddress == manager.ethContractAddress,
      "contractAddress is not equal to " & manager.ethContractAddress

    await manager.stop()

    let differentContractAddress = await uploadRLNContract(manager.ethClientUrl)
    # simulating a change in the contractAddress
    let manager2 = OnchainGroupManager(
      ethClientUrl: EthClient,
      ethContractAddress: $differentContractAddress,
      rlnInstance: manager.rlnInstance,
    )
    (await manager2.init()).isErrOr:
      raiseAssert "Expected error when contract address doesn't match"

  asyncTest "should error if contract does not exist":
    let manager = await setup()
    manager.ethContractAddress = "0x0000000000000000000000000000000000000000"

    expect(CatchableError):
      discard await manager.init()

  asyncTest "should error when keystore path and password are provided but file doesn't exist":
    let manager = await setup()
    manager.keystorePath = some("/inexistent/file")
    manager.keystorePassword = some("password")

    (await manager.init()).isErrOr:
      raiseAssert "Expected error when keystore file doesn't exist"

  asyncTest "startGroupSync: should start group sync":
    let manager = await setup()

    (await manager.init()).isOkOr:
      raiseAssert $error
    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

    await manager.stop()

  asyncTest "startGroupSync: should guard against uninitialized state":
    let manager = await setup()

    (await manager.startGroupSync()).isErrOr:
      raiseAssert "Expected error when not initialized"

    await manager.stop()

  asyncTest "startGroupSync: should sync to the state of the group":
    let manager = await setup()
    let credentials = generateCredentials(manager.rlnInstance)
    (await manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootBefore = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    let fut = newFuture[void]("startGroupSync")

    proc generateCallback(fut: Future[void]): OnRegisterCallback =
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        require:
          registrations.len == 1
          registrations[0].index == 0
        when defined(rln_v2):
          require:
            registrations[0].rateCommitment ==
              getRateCommitment(credentials, UserMessageLimit(1))
        else:
          require:
            registrations[0].idCommitment == credentials.idCommitment
        require:
          registrations[0].index == 0
        fut.complete()

      return callback

    try:
      manager.onRegister(generateCallback(fut))
      when defined(rln_v2):
        await manager.register(credentials, UserMessageLimit(1))
      else:
        await manager.register(credentials)
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await fut

    let merkleRootAfter = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    let metadataOpt = manager.rlnInstance.getMetadata().valueOr:
      raiseAssert $error
    check:
      metadataOpt.get().validRoots == manager.validRoots.toSeq()
      merkleRootBefore != merkleRootAfter
    await manager.stop()

  asyncTest "startGroupSync: should fetch history correctly":
    let manager = await setup()
    const credentialCount = 6
    let credentials = generateCredentials(manager.rlnInstance, credentialCount)
    (await manager.init()).isOkOr:
      raiseAssert $error

    let merkleRootBefore = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    type TestGroupSyncFuts = array[0 .. credentialCount - 1, Future[void]]
    var futures: TestGroupSyncFuts
    for i in 0 ..< futures.len():
      futures[i] = newFuture[void]()
    proc generateCallback(
        futs: TestGroupSyncFuts, credentials: seq[IdentityCredential]
    ): OnRegisterCallback =
      var futureIndex = 0
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        when defined(rln_v2):
          if registrations.len == 1 and
              registrations[0].rateCommitment ==
              getRateCommitment(credentials[futureIndex], UserMessageLimit(1)) and
              registrations[0].index == MembershipIndex(futureIndex):
            futs[futureIndex].complete()
            futureIndex += 1
        else:
          if registrations.len == 1 and
              registrations[0].idCommitment == credentials[futureIndex].idCommitment and
              registrations[0].index == MembershipIndex(futureIndex):
            futs[futureIndex].complete()
            futureIndex += 1

      return callback

    try:
      manager.onRegister(generateCallback(futures, credentials))
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error

      for i in 0 ..< credentials.len():
        when defined(rln_v2):
          await manager.register(credentials[i], UserMessageLimit(1))
        else:
          await manager.register(credentials[i])
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await allFutures(futures)

    let merkleRootAfter = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    check:
      merkleRootBefore != merkleRootAfter
      manager.validRootBuffer.len() == credentialCount - AcceptableRootWindowSize
    await manager.stop()

  asyncTest "register: should guard against uninitialized state":
    let manager = await setup()
    let dummyCommitment = default(IDCommitment)

    try:
      when defined(rln_v2):
        await manager.register(
          RateCommitment(
            idCommitment: dummyCommitment, userMessageLimit: UserMessageLimit(1)
          )
        )
      else:
        await manager.register(dummyCommitment)
    except CatchableError:
      assert true
    except Exception:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await manager.stop()

  asyncTest "register: should register successfully":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error
    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

    let idCommitment = generateCredentials(manager.rlnInstance).idCommitment
    let merkleRootBefore = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error

    try:
      when defined(rln_v2):
        await manager.register(
          RateCommitment(
            idCommitment: idCommitment, userMessageLimit: UserMessageLimit(1)
          )
        )
      else:
        await manager.register(idCommitment)
    except Exception, CatchableError:
      assert false,
        "exception raised when calling register: " & getCurrentExceptionMsg()

    let merkleRootAfter = manager.rlnInstance.getMerkleRoot().valueOr:
      raiseAssert $error
    check:
      merkleRootAfter.inHex() != merkleRootBefore.inHex()
      manager.latestIndex == 1
    await manager.stop()

  asyncTest "register: callback is called":
    let manager = await setup()

    let idCommitment = generateCredentials(manager.rlnInstance).idCommitment

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      require:
        registrations.len == 1
      when defined(rln_v2):
        require:
          registrations[0].rateCommitment ==
            RateCommitment(
              idCommitment: idCommitment, userMessageLimit: UserMessageLimit(1)
            )
      else:
        require:
          registrations[0].idCommitment == idCommitment
      require:
        registrations[0].index == 0
      fut.complete()

    manager.onRegister(callback)
    (await manager.init()).isOkOr:
      raiseAssert $error
    try:
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error
      when defined(rln_v2):
        await manager.register(
          RateCommitment(
            idCommitment: idCommitment, userMessageLimit: UserMessageLimit(1)
          )
        )
      else:
        await manager.register(idCommitment)
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    check await fut.withTimeout(5.seconds)

    await manager.stop()

  asyncTest "withdraw: should guard against uninitialized state":
    let manager = await setup()
    let idSecretHash = generateCredentials(manager.rlnInstance).idSecretHash

    try:
      await manager.withdraw(idSecretHash)
    except CatchableError:
      assert true
    except Exception:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await manager.stop()

  asyncTest "validateRoot: should validate good root":
    let manager = await setup()
    let credentials = generateCredentials(manager.rlnInstance)
    (await manager.init()).isOkOr:
      raiseAssert $error

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      when defined(rln_v2):
        if registrations.len == 1 and
            registrations[0].rateCommitment ==
            getRateCommitment(credentials, UserMessageLimit(1)) and
            registrations[0].index == 0:
          manager.idCredentials = some(credentials)
          fut.complete()
      else:
        if registrations.len == 1 and
            registrations[0].idCommitment == credentials.idCommitment and
            registrations[0].index == 0:
          manager.idCredentials = some(credentials)
          fut.complete()

    manager.onRegister(callback)

    try:
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error
      when defined(rln_v2):
        await manager.register(credentials, UserMessageLimit(1))
      else:
        await manager.register(credentials)
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await fut

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    when defined(rln_v2):
      let validProofRes = manager.generateProof(
        data = messageBytes, epoch = epoch, messageId = MessageId(1)
      )
    else:
      let validProofRes = manager.generateProof(data = messageBytes, epoch = epoch)

    require:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    # validate the root (should be true)
    let validated = manager.validateRoot(validProof.merkleRoot)

    check:
      validated
    await manager.stop()

  asyncTest "validateRoot: should reject bad root":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error
    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

    let credentials = generateCredentials(manager.rlnInstance)

    ## Assume the registration occured out of band
    manager.idCredentials = some(credentials)
    manager.membershipIndex = some(MembershipIndex(0))
    when defined(rln_v2):
      manager.userMessageLimit = some(UserMessageLimit(1))

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    when defined(rln_v2):
      let validProofRes = manager.generateProof(
        data = messageBytes, epoch = epoch, messageId = MessageId(0)
      )
    else:
      let validProofRes = manager.generateProof(data = messageBytes, epoch = epoch)
    require:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    # validate the root (should be false)
    let validated = manager.validateRoot(validProof.merkleRoot)

    check:
      validated == false
    await manager.stop()

  asyncTest "verifyProof: should verify valid proof":
    let manager = await setup()
    let credentials = generateCredentials(manager.rlnInstance)
    (await manager.init()).isOkOr:
      raiseAssert $error

    let fut = newFuture[void]()

    proc callback(registrations: seq[Membership]): Future[void] {.async.} =
      when defined(rln_v2):
        if registrations.len == 1 and
            registrations[0].rateCommitment ==
            getRateCommitment(credentials, UserMessageLimit(1)) and
            registrations[0].index == 0:
          manager.idCredentials = some(credentials)
          fut.complete()
      else:
        if registrations.len == 1 and
            registrations[0].idCommitment == credentials.idCommitment and
            registrations[0].index == 0:
          manager.idCredentials = some(credentials)
          fut.complete()

    manager.onRegister(callback)

    try:
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error
      when defined(rln_v2):
        await manager.register(credentials, UserMessageLimit(1))
      else:
        await manager.register(credentials)
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()
    await fut

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    when defined(rln_v2):
      let validProofRes = manager.generateProof(
        data = messageBytes, epoch = epoch, messageId = MessageId(0)
      )
    else:
      let validProofRes = manager.generateProof(data = messageBytes, epoch = epoch)
    require:
      validProofRes.isOk()
    let validProof = validProofRes.get()

    # verify the proof (should be true)
    let verifiedRes = manager.verifyProof(messageBytes, validProof)
    require:
      verifiedRes.isOk()

    check:
      verifiedRes.get()
    await manager.stop()

  asyncTest "verifyProof: should reject invalid proof":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error
    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

    let idCredential = generateCredentials(manager.rlnInstance)

    try:
      when defined(rln_v2):
        await manager.register(getRateCommitment(idCredential, UserMessageLimit(1)))
      else:
        await manager.register(idCredential.idCommitment)
    except Exception, CatchableError:
      assert false,
        "exception raised when calling startGroupSync: " & getCurrentExceptionMsg()

    let idCredential2 = generateCredentials(manager.rlnInstance)

    ## Assume the registration occured out of band
    manager.idCredentials = some(idCredential2)
    manager.membershipIndex = some(MembershipIndex(0))
    when defined(rln_v2):
      manager.userMessageLimit = some(UserMessageLimit(1))

    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    when defined(rln_v2):
      let invalidProofRes = manager.generateProof(
        data = messageBytes, epoch = epoch, messageId = MessageId(0)
      )
    else:
      let invalidProofRes = manager.generateProof(data = messageBytes, epoch = epoch)

    require:
      invalidProofRes.isOk()
    let invalidProof = invalidProofRes.get()

    # verify the proof (should be false)
    let verified = manager.verifyProof(messageBytes, invalidProof).valueOr:
      raiseAssert $error

    check:
      verified == false
    await manager.stop()

  asyncTest "backfillRootQueue: should backfill roots in event of chain reorg":
    let manager = await setup()
    const credentialCount = 6
    let credentials = generateCredentials(manager.rlnInstance, credentialCount)
    (await manager.init()).isOkOr:
      raiseAssert $error

    type TestBackfillFuts = array[0 .. credentialCount - 1, Future[void]]
    var futures: TestBackfillFuts
    for i in 0 ..< futures.len():
      futures[i] = newFuture[void]()

    proc generateCallback(
        futs: TestBackfillFuts, credentials: seq[IdentityCredential]
    ): OnRegisterCallback =
      var futureIndex = 0
      proc callback(registrations: seq[Membership]): Future[void] {.async.} =
        when defined(rln_v2):
          if registrations.len == 1 and
              registrations[0].rateCommitment ==
              getRateCommitment(credentials[futureIndex], UserMessageLimit(1)) and
              registrations[0].index == MembershipIndex(futureIndex):
            futs[futureIndex].complete()
            futureIndex += 1
        else:
          if registrations.len == 1 and
              registrations[0].idCommitment == credentials[futureIndex].idCommitment and
              registrations[0].index == MembershipIndex(futureIndex):
            futs[futureIndex].complete()
            futureIndex += 1

      return callback

    try:
      manager.onRegister(generateCallback(futures, credentials))
      (await manager.startGroupSync()).isOkOr:
        raiseAssert $error

      for i in 0 ..< credentials.len():
        when defined(rln_v2):
          await manager.register(credentials[i], UserMessageLimit(1))
        else:
          await manager.register(credentials[i])
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    await allFutures(futures)

    # At this point, we should have a full root queue, 5 roots, and partial buffer of 1 root
    require:
      manager.validRoots.len() == credentialCount - 1
      manager.validRootBuffer.len() == 1

    # We can now simulate a chain reorg by calling backfillRootQueue
    let expectedLastRoot = manager.validRootBuffer[0]
    try:
      await manager.backfillRootQueue(1)
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    # We should now have 5 roots in the queue, and no partial buffer
    check:
      manager.validRoots.len() == credentialCount - 1
      manager.validRootBuffer.len() == 0
      manager.validRoots[credentialCount - 2] == expectedLastRoot
    await manager.stop()

  asyncTest "isReady should return false if ethRpc is none":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error

    manager.ethRpc = none(Web3)

    var isReady = true
    try:
      isReady = await manager.isReady()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    check:
      isReady == false

    await manager.stop()

  asyncTest "isReady should return false if lastSeenBlockHead > lastProcessed":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error

    var isReady = true
    try:
      isReady = await manager.isReady()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    check:
      isReady == false

    await manager.stop()

  asyncTest "isReady should return true if ethRpc is ready":
    let manager = await setup()
    (await manager.init()).isOkOr:
      raiseAssert $error
    # node can only be ready after group sync is done
    (await manager.startGroupSync()).isOkOr:
      raiseAssert $error

    var isReady = false
    try:
      isReady = await manager.isReady()
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    check:
      isReady == true

    await manager.stop()

  ################################
  ## Terminating/removing Anvil
  ################################

  # We stop Anvil daemon
  stopAnvil(runAnvil)

import
  # Standard library
  atomics, locks, random,
  # Internal
  ./deque_list_tl, ./channel,
  ./bounded_stack, ./bounded_queue,
  ./worker_tree,
  ./tasking_internal,
  ./partition, task,
  ./platform, ./bitfield,
  primitives/c,
  ./profile

type Channel = channel.Channel

template log(args: varargs[untyped]): untyped =
  printf(args)
  flushFile(stdout)

const MaxSteal {.intdefine.} = 1
  # TODO add to compile-time flags

var deque {.threadvar.}: DequeListTL
  ## Thread-local task deque

var chan_requests: array[MaxWorkers, Channel]
 ## Worker -> worker: intra-partition steal requests (MPSC)

var chan_tasks: array[MaxWorkers, array[MaxSteal, Channel]]
 ## Worker -> worker: tasks (SPSC)

var channel_stack {.threadvar.}: BoundedStack[MaxSteal, Channel]
 ## Every worker maintains a stack of (recycled) channels to
 ## keep track of which channels to use for the next steal requests

proc channel_push(chan: sink Channel) {.inline.} =
  channel_stack.bounded_stack_push(chan)

proc channel_pop(): Channel {.inline.} =
  channel_stack.bounded_stack_pop()

when defined(VictimCheck):
  # TODO - add to compilation flags
  type TaskIndicator = object
    tasks: Atomic[bool]
    padding: array[64 - sizeof(Atomic[bool]), byte]

  var task_indicators: array[MaxWorkers, TaskIndicator]

  template likely_has_tasks(id: int32): bool {.dirty.} =
    task_indicators[id].tasks.load(moRelaxed) > 0

  template have_tasks() {.dirty.} =
    task_indicators[id].tasks.store(true, moRelaxed)

  template have_no_tasks() {.dirty.} =
    task_indicators[id].tasks.store(false, moRelaxed)

else:
  template likely_has_tasks(id: int32): bool =
    true

  template have_tasks() {.dirty.} =
    discard

  template have_no_tasks() {.dirty.} =
    discard


# When a steal request is returned to its sender after MAX_STEAL_ATTEMPTS
# unsuccessful attempts, the steal request changes state to STATE_FAILED and
# is then passed on to tree.parent as a work sharing request: the parent holds
# on to this request until it can send tasks in return. Thus, when a worker
# receives a steal request whose state is STATE_FAILED, the sender is either
# tree.left_child or tree.right_child. At this point, there is a "lifeline"
# between parent and child: the child will not send further steal requests
# until it receives new work from its parent. We have switched from work
# stealing to work sharing. This also means that backing off from work
# stealing by withdrawing a steal request for a short while is no longer
# needed, as steal requests are withdrawn automatically.
#
# Termination occurs once worker 0 detects that both left and right subtrees
# of workers are idle and worker 0 is itself idle.
#
# When a worker receives new work, it must check its "lifelines" (queue of
# work sharing requests) and try to distribute as many tasks as possible,
# thereby reactivating workers further down in the tree.

type
  WorkerState = enum
    ## Steal requests carry one of the following states:
    ## - STATE_WORKING means the requesting worker is (likely) still busy
    ## - STATE_IDLE means the requesting worker has run out of tasks
    ## - STATE_FAILED means the requesting worker backs off and waits for tasks
    ##   from its parent worker
    Working
    Idle
    Failed

  StealRequest = object
    chan: Channel             # Channel for sending tasks
    ID: int32                 # ID of requesting worker
    retry: int32              # 0 <= tries <= num_workers_rt
    partition: int32          # partition in which the steal request was initiated
    pID: int32                # ID of requesting worker within partition
    victims: Bitfield[uint32] # Bitfield of potential victims
    state: WorkerState        # State of steal request and by extension requestion worker
    when StealStrategy == StealKind.adaptative:
      stealhalf: bool
      pad: array[2, byte]
    else:
      pad: array[3, byte]

template init_victims(): untyped =
  # `my_partition`: thread-local from partition.nim after running `partition_init`
  initBitfieldSetUpTo(uint32, my_partition.num_workers_rt)

template steal_request_init(): StealRequest =
  when StealStrategy == StealKind.adaptative:
    StealRequest(
      chan: channel_pop(),
      id: ID, # thread-local var from tasking_internal.ni
      retry: 0,
      partition: my_partition.number, # `my_partition`: thread-local from partition.nim after running `partition_init`
      pID: pID, # thread-local from runtime.nim, defined later
      victims: init_victims(),
      state: Working,
      stealhalf: stealhalf # thread-local from runtime.nim, defined later
    )
  else:
    StealRequest(
      chan: channel_pop(),
      ID: ID, # thread-local var from tasking_internal.ni
      retry: 0,
      partition: my_partition.number, # `my_partition`: thread-local from partition.nim after running `partition_init`
      pID: pID, # thread-local from runtime.nim, defined later
      victims: init_victims(),
      state: Working
    )

var work_sharing_requests{.threadvar.}: BoundedQueue[2, StealRequest]
  ## Every worker has a queue where it keeps the failed steal requests of its
  ## children until work can be shared.
  ## A worker has between 0 and 2 children.

proc enqueue_work_sharing_request(req: StealRequest) {.inline.} =
  bounded_queue_enqueue(work_sharing_requests, req)

proc dequeue_work_sharing_request(): ptr StealRequest {.inline.} =
  bounded_queue_dequeue(work_sharing_requests)

proc next_work_sharing_request(): ptr StealRequest {.inline.} =
  bounded_queue_head(work_sharing_requests)

var requested {.threadvar.}: int32
  ## A worker can have up to MAXSTEAL outstanding steal requests

var dropped_steal_requests {.threadvar.}: int32
  ## Before a worker can become quiescent, it has to drop MAXSTEAL-1
  ## steal requests and send the remaining one to its parent

var tree {.threadvar.}: WorkerTree
  ## Worker tree related information is collected in this struct

when defined(StealLastVictim):
  var last_victim {.threadvar.} = -1
when defined(StealLastThief):
  var last_thief {.threadvar.} = -1

var victims {.threadvar.}: ptr array[MaxWorkers, int32]
  # Not to be confused with victim bitfield

var pID {.threadvar.}: int32
  ## A worker has a unique ID within its partition
  ## 0 <= pID <= num_workers_rt

var print_mutex: Lock
initLock(print_mutex)

template lprintf(args: varargs[untyped]): untyped =
  ## Printf wrapped in a lock for multithreading consistency
  acquire(print_mutex)
  printf(args)
  flushFile(stdout)
  release(print_mutex)

proc print_victims(victims: Bitfield[uint32], ID: int32) =
  assert my_partition.num_workers_rt in 1..32

  acquire(print_mutex)
  printf("victims[%2d] = ", ID)

  for i in countdown(31, my_partition.num_workers_rt):
    stdout.write('.')

  for i in countdown(my_partition.num_workers_rt-1, 0):
    stdout.write uint8(victims.isSet(i))

  stdout.write '\n'
  release(print_mutex)

proc init_victims(ID: int32) =
  ## Currently only needed to count the number of workers

  var j = 0

  # Get all available worker in my_partition
  for i in 0 ..< my_partition.num_workers:
    let worker = my_partition.workers[i]
    if worker < num_workers: # Global taken from WEAVE_NUM_THREADS in tasking_internals
      victims[j] = worker
      inc j
      inc my_partition.num_workers_rt

  Master log("Manager %2d: %d of %d workers available\n", ID,
             my_partition.num_workers_rt, my_partition.num_workers)

var thread_rng {.threadvar.}: Rand

proc ws_init() =
  ## Initializes the context needed for work-stealing
  thread_rng = initRand(ID + 1000) # seed must be non-zero
  init_victims(ID)

proc mark_as_idle(victims: var BitField[uint32], n: int32) =
  ## Requires -1 <= n < num_workers
  if n == -1:
    # Invalid worker ID (parent of root or out-of-bound child)
    return

  let maxID = my_partition.num_workers_rt - 1

  if n < num_workers:
    mark_as_idle(victims, left_child(n, maxID))
    mark_as_idle(victims, right_child(n, maxID))
    # Unset worker n
    victims.clearBit(n.uint32)

func rightmost_victim(victims: Bitfield[uint32], ID: int32): int32 =
  result = getLSBset(victims)
  if result == ID:
    # If worker gets its own ID as victim
    # TODO - why would the bitfield be set with its own worker ID?
    let clearedLSB = victims.lsbSetCleared()
    if clearedLSB.isEmpty():
      result = -1
    else:
      result = clearedLSB.getLSBset()

  {.noSideEffect.}:
    assert(
      # Victim found
      ((result in 0 ..< my_partition.num_workers_rt) and
      result != ID) or
      # No victim found
      result == -1
    )

var random_receiver_calls {.threadvar.}: int32
var random_receiver_early_exits {.threadvar.}: int32

proc random_victim(victims: BitField[uint32], ID: int32): int32 =
  ## Choose a random victim != ID from the list of potential victims

  inc random_receiver_calls
  inc random_receiver_early_exits

  # No eligible victim? Return message to sender
  if victims.isEmpty():
    return -1

  # Try to choose a victim at random
  for i in 0 ..< 3:
    let victim = int32 thread_rng.rand(my_partition.num_workers_rt - 1)
    if victims.isSet(victim) and victim != ID:
      return victim

  # We didn't early exit, i.e. not enough potential victims
  # for completely randomized selection
  dec random_receiver_early_exits

  # Build the list of victims
  let num_victims = countSetBits(victims)
  assert num_victims in 0 ..< my_partition.num_workers_rt

  # Length of array is upper-bounded by the number of workers but
  # num_victims is likely less than that or we would
  # have found a victim above
  #
  # Unfortunaly VLA (Variable-Length-Array) are only available in C99
  # So we emulate them with alloca.
  #
  # num_victims is probably quite low compared to num_workers
  # i.e. 2 victims for a 16-core CPU hence we save a lot of stack.
  #
  # Heap allocation would make the system allocator
  # a multithreaded bottleneck on fine-grained tasks
  var potential_victims = alloca(int32, num_victims)

  # Map potential_victims with real IDs
  var n = victims.buffer
  var i, j: int32
  while n != 0:
    if bool(n and 1):
      # Test first bit
      potential_victims[j] = i
      inc j
    inc i
    n = n shr 1

  assert j == num_victims

  result = potential_victims[thread_rng.rand(num_victims-1)]
  assert victims.isSet(result)

  assert(
    ((result in 0 ..< my_partition.num_workers_rt) and
    result != ID)
  )

# To profile different parts of the runtime
profile_decl(run_task)
profile_decl(enq_deq_task)
profile_decl(send_recv_task)
profile_decl(send_recv_req)
profile_decl(idle)

var
  requests_sent {.threadvar.}: int32
  requests_handled {.threadvar.}: int32
  requests_declined {.threadvar.}: int32
  tasks_sent {.threadvar.}: int32
  tasks_split {.threadvar.}: int32

when defined(LazyFutures):
  # TODO: add to compilation flags
  var futures_converted {.threadvar.}: int32

proc RT_init() =
  ## Initialize the multithreading runtime

  # Small sanity checks
  # At this point, we have not yet decided who will be manager(s)
  assert is_manager == false # from partition.nim
  static:
    assert sizeof(StealRequest) == 32
    # assert sizeof(Task()[]) == 192 - checked in task.nim

  # TODO: following the global variables flow is very hard
  # This requires being called after `tasking_internal_init`
  assert num_workers > 0
  partition_assign_xlarge(MasterID)
  partition_set()
  assert not my_partition.isNil

  if is_manager:
    assert ID == MasterID

  deque = deque_list_tl_new()

  Master:
    # Unprocessed update message followed by new steal request
    # => up to two messages per worker (assuming MaxSteal == 1)
    chan_requests[ID] = channel_alloc(
      int32 sizeof(StealRequest), MaxSteal * num_workers * 2, Mpsc
    )
  Worker:
    chan_requests[ID] = channel_alloc(
      int32 sizeof(StealRequest), MaxSteal * num_workers, Mpsc
    )

  # At most MaxSteal steal requests and thus different channels
  channel_stack = bounded_stack_alloc(Channel, MaxSteal)

  # Being able to send N steal requests requires either a single MPSC or
  # N SPSC channels
  for i in 0 ..< MaxSteal:
    chan_tasks[ID][i] = channel_alloc(int32 sizeof(Task), 1, Spsc)
    channel_push(chan_tasks[ID][i])

  assert channel_stack.top == MaxSteal

  victims = cast[ptr array[MaxWorkers, int32]](malloc(int32, MaxWorkers))

  ws_init()

  for i in 0 ..< my_partition.num_workers_rt:
    if ID == my_partition.workers[i]:
      pID = i
      break

  requested = 0

  when defined(VictimCheck):
    static: assert sizeof(TaskIndicator) == 64
    task_indicators[ID].tasks.store(false)

  # a worker has between zero and 2 children
  work_sharing_requests = bounded_queue_alloc(StealRequest, 2)

  # The worker tree is a complete binary tree with worker 0 at the root
  worker_tree_init(tree, ID, my_partition.num_workers_rt - 1)

  profile_init(run_task)
  profile_init(enq_deq_task)
  profile_init(send_recv_task)
  profile_init(send_recv_req)
  profile_init(idle)

proc RT_exit() =
  deque_list_tl_delete(deque)
  free(victims)

  channel_free(chan_requests[ID])
  when ChannelCacheSize > 0:
    channel_cache_free()

  for i in 0 ..< MaxSteal:
    # No tasks left in channel
    assert channel_peek(chan_tasks[ID][i]) == 0
    channel_free(chan_tasks[ID][i])

  bounded_stack_free(channel_stack)
  bounded_queue_free(work_sharing_requests)

  partition_reset()

  log("Worker %d: random_receiver fast path (slow path): %3.0f %% (%3.0f %%)\n",
    ID, random_receiver_early_exits.float64 * 100 / random_receiver_calls.float64,
    100 - random_receiver_early_exits.float64 * 100 / random_receiver_calls.float64
  )

proc task_alloc(): Task =
  deque_list_tl_task_new(deque)

when not defined(MaxStealAttempts):
  assert not my_partition.isNil
  let MaxStealAttempts = my_partition.num_workers_rt - 1
    ## Number of steal attempts before a steal request is sent back to the thief
    ## Default value is the number of workers minus one

proc next_victim(req: var StealRequest): int32 =
  result = -1

  req.victims.clearBit(ID.uint32)

  if req.ID == ID:
    assert req.retry == 0
    # Initially: send message to random worker != ID
    result = int32 thread_rng.rand(my_partition.num_workers_rt - 1)
    while result == ID:
      result = int32 thread_rng.rand(my_partition.num_workers_rt - 1)
  elif req.retry == MaxStealAttempts:
    # Return steal request to thief
    # print_victims(req.victims, req.ID)
    result = req.ID
  else:
    # Forward steal reques to different worker != ID, if possible
    if tree.left_subtree_is_idle and tree.right_subtree_is_idle:
      mark_as_idle(req.victims, ID)
    elif tree.left_subtree_is_idle:
      mark_as_idle(req.victims, tree.left_child)
    elif tree.right_subtree_is_idle:
      mark_as_idle(req.victims, tree.right_child)
    assert not req.victims.isSet(ID)
    result = random_victim(req.victims, req.ID)

  if result == -1:
    # Couldn't find victim; return steal request to thief
    assert req.victims.isEmpty()
    result = req.ID

  when false:
    if result == req.ID:
      log("%d -{%d}-> %d after %d tries (%u ones)\n",
        ID, req.ID, victim, req,retry, countSetBits(req.victims)
      )

  assert result in 0 ..< my_partition.num_workers_rt
  assert result != ID
  assert req.retry in 0 ..< MaxStealAttempts

when defined(StealLastVictim) or defined(StealLastThief):
  proc steal_from(req: var StealRequest, worker: int32): int32 =
    if req.retry < MaxStealAttempts:
      if worker != -1 and worker != req.ID and likely_has_tasks(worker):
        return worker
      # Worker is unavailable, fallback to random victim selection
      return next_victim(req)
    return req.ID

# Forward declarations
proc try_send_steal_request(idle: bool)
# proc decline_steal_request(req: var StealRequest)
# proc decline_all_steal_requests()
# proc split_loop(task: Task, req: sink StealRequest)

proc send_req(chan: Channel, req: sink StealRequest) {.inline.} =
  var nfail = 0
  while not channel_send(chan, req.unsafeAddr, int32 sizeof(req)):
    inc nfail
    if nfail mod 3 == 0:
      log("*** Worker %d: blocked on channel send\n", ID)
      # raising an exception in a thread will probably crash, oh well ...
      raise newException(DeadThreadError, "Worker blocked! Check channel capacities!")
    if tasking_done():
      break

proc send_req_worker(ID: int32, req: sink StealRequest) {.inline.} =
  send_req(chan_requests[ID], req)

proc send_req_manager(req: sink StealRequest) {.inline.} =
  send_req(chan_requests[my_partition.manager], req)

proc recv_req(req: var StealRequest): bool =
  profile(send_recv_req):
    result = channel_receive(chan_requests[ID], req.addr, int32 sizeof(req))
    while result and req.state == Failed:
      when defined(DebugTD):
        # Termination detection
        # TODO: add to compile-time options
        log("Worker %d receives STATE_FAILED from worker %d\n", ID, req.ID)
      assert(req.ID == tree.left_child or req.ID == tree.right_child)
      if req.ID == tree.left_child:
        assert not tree.left_subtree_is_idle
        tree.left_subtree_is_idle = true
      else:
        assert not tree.right_subtree_is_idle
        tree.right_subtree_is_idle = true
      # Hold on to this steal request
      enqueue_work_sharing_request(req)
      result = channel_receive(chan_requests[ID], req.addr, int32 sizeof(req))

    # No special treatment for other states
    assert((result and req.state != Failed) or not result)

proc recv_task(task: var Task, idle: bool): bool =
  profile(send_recv_task):
    for i in 0 ..< MaxSteal:
      result = channel_receive(chan_tasks[ID][i], task.addr, int32 sizeof(Task))
      if result:
        channel_push(chan_tasks[ID][i])
        break

  if not result:
    try_send_steal_request(idle)
  else:
    template tree_waiting_for_tasks(): untyped {.dirty.} =
      assert requested == MaxSteal
      assert channel_stack.top == MaxSteal
      # Adjust value of requested by MaxSteal-1, the number of steal
      # requests that have been dropped:
      # requested = requested - (MaxSteal-1) =
      #           = MaxSteal - MaxSteal + 1 = 1
      requested = 1
      tree.waiting_for_tasks = false
      dropped_steal_requests = 0
    when MaxSteal > 1:
      if tree.waiting_for_tasks:
        tree_waiting_for_tasks()
      else:
        # If we have dropped one or more steal requests before receiving
        # tasks, adjust requested to make sure that we can send MaxSteal
        # steal requests again
        if dropped_steal_requests > 0:
          assert requested > dropped_steal_requests
          requested -= dropped_steal_requests
          dropped_steal_requests = 0
    else:
      if tree.waiting_for_tasks:
        tree_waiting_for_tasks()

    dec requested
    assert requested in 0 ..< MaxSteal
    assert dropped_steal_requests == 0

const StealAdaptativeInterval{.intdefine.} = 25
  ## Number of steals after which the current strategy is reevaluated
  # TODO: add to compile-time config

var
  num_tasks_exec_recently {.threadvar.}: int32
  num_steals_exec_recently {.threadvar.}: int32
  stealhalf {.threadvar.}: bool
  requests_steal_one {.threadvar.}: int32
  requests_steal_half {.threadvar.}: int32

proc try_send_steal_request(idle: bool) =
  ## Try to send a steal request
  ## Every worker can have at most MaxSteal pending steal requests.
  ## A steal request with idle == false indicates that the
  ## requesting worker is still busy working on some tasks.
  ## A steal request with idle == true indicates that
  ## the requesting worker is idle and has nothing to work on

  profile(send_recv_req):
    if requested < MaxSteal:
      when StealStrategy == StealKind.adaptative:
        # Estimate work-stealing efficiency during the last interval
        # If the value is below a threshold, switch strategies
        if num_steals_exec_recently == StealAdaptativeInterval:
          let ratio = num_tasks_exec_recently.float64 / StealAdaptativeInterval.float64
          if stealhalf and ratio < 2:
            stealhalf = false
          elif not stealhalf and ratio == 1:
            stealhalf = true
          num_tasks_exec_recently = 0
          num_steals_exec_recently = 0
      # The following assertion no longer holds because we may increment
      # channel_stack.top without decrementing requested
      # (see dcline_steal_request):
      # assert(requested + channel_stack.top == MaxSteal)
      var req = steal_request_init()
      req.state = if idle: Idle else: Working
      assert req.retry == 0

      when defined(StealLastVictim):
        send_req_worker(steal_from(req, last_victim), req)
      elif defined(StealLastThief):
        send_req_worker(steal_from(req, last_thief), req)
      else:
        send_req_worker(next_victim(req), req)

      inc requested
      inc requests_sent

      when StealStrategy == StealKind.adaptative:
        if stealhalf:
          inc requests_steal_half
        else:
          inc requests_steal_one

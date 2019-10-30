defmodule BroadwayKafka.Producer do
  @moduledoc """
  A Kafka producer for Broadway that consumes messages from a Kafka consumer group.

  ## Options

    * `:hosts` - Required. A keyword list of host/port pairs to use for establishing the
       initial connection to Kafka, e.g. [localhost: 9092].

    * `:group_id` - Required. A unique string that identifies the consumer group the
       producer will belong to.

    * `:topics` - Required. A list of topics or a keyword list of topic/partition that
      the producer will subscribe to.

    * `:receive_interval` - Optional. The duration (in milliseconds) for which the producer
      waits before making a request for more messages. Default is 2000 (2 seconds).

    * `:group_config` - Optional. A list of options used to configure the group
      coordinator. See the "Group config options" section below for a list of all available
      options.

    * `:fetch_config` - Optional. A list of options used when fetching messages. See the
      "Fetch config options" section below for a list of all available options.

  ## Group config options

  The avaiable options that will be passed to `:brod`'s group coordinator.

    * `:offset_commit_interval_seconds` - Optional. The time interval between two
       OffsetCommitRequest messages. Default is 5.

    * `:rejoin_delay_seconds` - Delay in seconds before re-joining the group. Default is 1.

  ## Fetch config options

  The avaiable options that will be internally passed to `:brod.fetch/5`.

    * `:min_bytes` - Optional. The minimum amount of data to be fetched from the server.
      If not enough data is available the request will wait for that much data to accumulate
      before answering. Default is 1 byte. Setting this value greater than 1 can improve
      server throughput a bit at the cost of additional latency.

    * `:max_bytes` - Optional. The maximum amount of data to be fetched from the server.
      Default is 1048576 (1 MiB).

  > Note: Currently, Broadway does not support all options avaiable for `:brod`. If you
  have a scenario where you need any extra option that is not listed above, please open an
  issue, so we can consider adding it.

  ## Example

      Broadway.start_link(MyBroadway,
        name: MyBroadway,
        producer: [
          module: {BroadwayKafka.Producer, [
            hosts: [localhost: 9092],
            group_id: "group_1",
            topics: ["test"],
            receive_interval: 1000,
            group_config: [
              offset_commit_interval_seconds: 5,
              rejoin_delay_seconds: 2
            ]
          ]},
          stages: 5
        ],
        processors: [
          default: []
        ]
      )
  """


  use GenStage

  require Logger
  import Record, only: [defrecord: 2, extract: 2]

  alias Broadway.{Message, Acknowledger, Producer}
  alias BroadwayKafka.Allocator
  alias BroadwayKafka.Acknowledger

  @behaviour Producer
  @behaviour :brod_group_member

  defrecord :kafka_message, extract(:kafka_message, from_lib: "brod/include/brod.hrl")
  defrecord :brod_received_assignment, extract(:brod_received_assignment, from_lib: "brod/include/brod.hrl")

  @default_receive_interval 2000

  @impl GenStage
  def init(opts) do
    client = opts[:client] || BroadwayKafka.BrodClient
    receive_interval = opts[:receive_interval] || @default_receive_interval

    case client.init(opts) do
      {:error, message} ->
        raise ArgumentError, "invalid options given to #{inspect(client)}.init/1, " <> message

      {:ok, config} ->
        {_, producer_name} = Process.info(self(), :registered_name)
        client_id = Module.concat([producer_name, Client])
        state = %{
          client: client,
          client_id: client_id,
          group_coordinator: nil,
          receive_timer: nil,
          receive_interval: receive_interval,
          acks: Acknowledger.new,
          config: config,
          broadway_index: opts[:broadway][:index],
          broadway_name: opts[:broadway][:name],
          processors_names: Keyword.keys(opts[:broadway][:processors]),
          batchers_names: Keyword.keys(opts[:broadway][:batchers]),
          draining: false,
          drain_caller: nil,
          demand: 0
        }
        {:producer, connect(state), buffer_size: :infinity}
    end
  end

  @impl GenStage
  def handle_demand(incoming_demand, %{demand: demand} = state) do
    maybe_schedule_poll(%{state | demand: demand + incoming_demand}, 0)
  end

  @impl GenStage
  def handle_call(:drain_messages, _from, %{draining: true} = state) do
    {:reply, :ok, [], state}
  end

  @impl GenStage
  def handle_call(:drain_messages, from, state) do
    if Acknowledger.all_drained?(state.acks) do
      {:reply, :ok, [], %{state | acks: Acknowledger.new}}
    else
      {:noreply, [], %{state | draining: true, drain_caller: from}}
    end
  end

  @impl GenStage
  def handle_info({:poll, key}, state) do
    if Acknowledger.has_key?(state.acks, key) do
      {_current, offset, _pending} = state.acks[key]
      {messages, n_messages, new_offset} = fetch_messages_from_kafka(state, key, offset)
      new_demand = max(0, state.demand - n_messages)

      new_state =
        %{state |
          acks: Acknowledger.update_last_offset(state.acks, key, new_offset),
          demand: new_demand
        }

      {:noreply, messages, new_state}
    else
      {:noreply, [], state}
    end
  end

  @impl GenStage
  def handle_info(:maybe_schedule_poll, state) do
    maybe_schedule_poll(%{state | receive_timer: nil}, state.receive_interval)
  end

  @impl GenStage
  def handle_info({:put_assignments, group_generation_id, assignments}, state) do
    list =
      Enum.map(assignments, fn assignment ->
        brod_received_assignment(
          topic: topic,
          partition: partition,
          begin_offset: begin_offset
        ) = assignment

        # TODO: Is it guaranteed that we can always send `0` for new topics?
        offset = if begin_offset == :undefined, do: 0, else: begin_offset
        {group_generation_id, topic, partition, offset}
      end)

    topics_partitions = Enum.map(list, fn {_, topic, partition, _} -> {topic, partition} end)

    # TODO: Update this to broadway master. Note on master
    # it will receive the same options as prepare_for_start
    # but under the broadway key, so it may be possible that
    # you can share some of this functionality (such as naming)
    # with prepare_for_start.
    broadway_name = state.broadway_name

    [processor_name | _] = state.processors_names
    broadway_index = state.broadway_index
    allocator_name = Module.concat([broadway_name, "Allocator_processor_#{processor_name}"])
    Allocator.allocate(allocator_name, broadway_index, topics_partitions)

    for name <- state.batchers_names do
      allocator_name = Module.concat([broadway_name, "Allocator_batcher_consumer_#{name}"])
      Allocator.allocate(allocator_name, broadway_index, topics_partitions)
    end

    {:noreply, [], %{state | acks: Acknowledger.add(state.acks, list)}}
  end

  @impl GenStage
  def handle_info({:ack, key, offsets}, state) do
    %{group_coordinator: group_coordinator, client: client, acks: acks} = state
    {generation_id, topic, partition} = key

    {drained?, new_offset, updated_acks} = Acknowledger.update_current_offset(acks, key, offsets)

    if new_offset do
      try do
        client.ack(group_coordinator, generation_id, topic, partition, new_offset)
      catch
        kind, reason ->
          Logger.error(Exception.format(kind, reason, System.stacktrace()))
      end
    end

    new_state =
      if drained? && state.draining && Acknowledger.all_drained?(updated_acks) do
        GenStage.reply(state.drain_caller, :ok)
        %{state | draining: false, drain_caller: nil, acks: Acknowledger.new}
      else
        %{state | acks: updated_acks}
      end

    {:noreply, [], new_state}
  end

  @impl GenStage
  def handle_info(_, state) do
    {:noreply, [], state}
  end

  @impl Producer
  def prepare_for_draining(_) do
    # TODO: Implement draining or document why one is not necessary.
    :ok
  end

  @impl Producer
  def prepare_for_start(_module, opts) do
    broadway_name = opts[:name]

    producers_stages = opts[:producer][:stages]
    [first_processor_entry | other_processors_entries] = opts[:processors]

    {allocator, updated_processor_entry} =
      build_allocator_spec_and_consumer_entry(broadway_name, "processor", producers_stages, first_processor_entry)

    {allocators, updated_batchers_entries} =
      Enum.reduce(opts[:batchers], {[allocator], []}, fn entry, {allocators, entries} ->
        {allocator, updated_entry} =
          build_allocator_spec_and_consumer_entry(broadway_name, "batcher_consumer", producers_stages, entry)
        {[allocator | allocators], [updated_entry | entries]}
      end)

    updated_opts =
      opts
      |> Keyword.put(:processors, [updated_processor_entry | other_processors_entries])
      |> Keyword.put(:batchers, updated_batchers_entries)

    {allocators, updated_opts}
  end

  @impl :brod_group_member
  def get_committed_offsets(_pid, _topics_partitions) do
    {:ok, [], -1}
  end

  @impl :brod_group_member
  def assignments_received(pid, _group_member_id, group_generation_id, received_assignments) do
    send(pid, {:put_assignments, group_generation_id, received_assignments})
    :ok
  end

  @impl :brod_group_member
  def assignments_revoked(producer_pid) do
    GenStage.call(producer_pid, :drain_messages, :infinity)
    :ok
  end

  defp maybe_schedule_poll(%{receive_timer: nil, demand: demand} = state, interval) when demand > 0 do
    for key <- Acknowledger.keys(state.acks) do
      Process.send_after(self(), {:poll, key}, interval)
    end

    ref = Process.send_after(self(), :maybe_schedule_poll, interval)
    {:noreply, [], %{state | receive_timer: ref}}
  end

  defp maybe_schedule_poll(state, _interval) do
    {:noreply, [], state}
  end

  defp fetch_messages_from_kafka(%{draining: true}, _key, offset) do
    {[], 0, offset}
  end

  defp fetch_messages_from_kafka(state, key, offset) do
    %{
      client: client,
      client_id: client_id,
      config: config
    } = state

    {generation_id, topic, partition} = key

    case client.fetch(client_id, topic, partition, offset, config[:fetch_config], config) do
      {:ok, {_watermark_offset, kafka_messages}} ->
        {messages, n_messages, new_offset} =
          Enum.reduce(kafka_messages, {[], 0, offset}, fn k_msg, {messages, count, _new_offset} ->
            msg = wrap_message(k_msg, topic, partition, generation_id)
            {[msg | messages], count + 1, msg.metadata.offset + 1}
          end)

        {Enum.reverse(messages), n_messages, new_offset}

      {:error, reason} ->
        # TODO: Treat the error properly
        IO.inspect(reason, label: "ERROR")
        {[], 0, offset}
    end
  end

  defp wrap_message(kafka_msg, topic, partition, generation_id) do
    kafka_message(value: data, offset: offset, key: key, ts: ts) = kafka_msg

    ack_data = %{offset: offset}
    ack_ref = {self(), {generation_id, topic, partition}}
    message =
      %Message{
        data: data,
        metadata: %{topic: topic, partition: partition, offset: offset, key: key, ts: ts},
        acknowledger: {Acknowledger, ack_ref, ack_data}
      }

    Message.put_batch_key(message, {topic, partition})
  end

  defp connect(state) do
    %{client: client, client_id: client_id, config: config} = state

    case client.setup(self(), client_id, __MODULE__, config) do
      {:ok, group_coordinator} ->
        %{state | group_coordinator: group_coordinator}

      error ->
        #TODO
        raise "Setup failed: #{inspect(error)}"
    end
  end

  defp build_allocator_spec_and_consumer_entry(broadway_name, prefix, producers_stages, consumer_entry) do
    {consumer_name, consumer_config} = consumer_entry
    consumer_stages = consumer_config[:stages]
    allocator_name = Module.concat([broadway_name, "Allocator_#{prefix}_#{consumer_name}"])
    partition_by = &Allocator.fetch!(allocator_name, {&1.metadata.topic, &1.metadata.partition})
    # TODO: we should raise if the user set the partition_by themselves
    new_config = Keyword.put(consumer_config, :partition_by, partition_by)
    allocator = {BroadwayKafka.Allocator, {allocator_name, producers_stages, consumer_stages}}
    allocator_spec = Supervisor.child_spec(allocator, id: allocator_name)

    {allocator_spec, {consumer_name, new_config}}
  end
end

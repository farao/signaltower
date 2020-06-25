defmodule SignalTower.Room do
  use GenServer, restart: :transient

  alias SignalTower.Room
  alias SignalTower.Room.{Member, Membership, Supervisor}
  alias SignalTower.Stats

  ## API ##

  def start_link(room_id) do
    name = "room_#{room_id}" |> String.to_atom()
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def create(room_id) do
    case DynamicSupervisor.start_child(Supervisor, {Room, [room_id]}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  def join_and_monitor(room_id, status, turn_timeout) do
    room_pid = create(room_id)
    Process.monitor(room_pid)

    {own_id, new_turn_timeout} = GenServer.call(room_pid, {:join, self(), status, turn_timeout})

    membership = %Membership{id: room_id, pid: room_pid, own_id: own_id, own_status: status}
    %{room: membership, turn_timeout: new_turn_timeout}
  end

  ## Callbacks ##

  @impl GenServer
  def init(_) do
    GenServer.cast(Stats, {:room_created, self()})
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:join, pid, status, turn_timeout}, _, members) do
    GenServer.cast(Stats, {:peer_joined, self(), map_size(members) + 1})

    Process.monitor(pid)
    peer_id = UUID.uuid1()
    new_turn_timeout = send_joined_room(pid, peer_id, members, turn_timeout)
    send_new_peer(members, peer_id, status)

    new_member = %Member{peer_id: peer_id, pid: pid, status: status}
    {:reply, {peer_id, new_turn_timeout}, Map.put(members, peer_id, new_member)}
  end

  @impl GenServer
  def handle_call({:leave, peer_id}, _, state) do
    case leave(peer_id, state) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:stop, state} ->
        {:stop, :normal, :ok, state}

      {:error, state} ->
        {:reply, :error, state}
    end
  end

  @impl GenServer
  def handle_cast({:send_to_peer, peer_id, msg, sender_id}, members) do
    if members[sender_id] && members[peer_id] do
      send(members[peer_id].pid, {:to_user, Map.put(msg, :sender_id, sender_id)})
    end

    {:noreply, members}
  end

  @impl GenServer
  def handle_cast({:update_status, sender_id, status}, members) do
    if members[sender_id] do
      update_status = %{
        event: "peer_updated_status",
        sender_id: sender_id,
        status: status
      }

      Map.delete(members, sender_id)
      |> send_to_all(update_status)
    end

    {:noreply, members}
  end

  # invoked when a user session exits
  @impl GenServer
  def handle_info({:DOWN, _ref, _, pid, _}, members) do
    members
    |> Enum.find(fn {_, member} -> pid == member.pid end)
    |> case do
      {id, _} ->
        case leave(id, members) do
          {:ok, state} -> {:noreply, state}
          {:error, state} -> {:noreply, state}
          {:stop, state} -> {:stop, :normal, state}
        end

      _ ->
        {:noreply, members}
    end
  end

  defp leave(peer_id, members) do
    if members[peer_id] do
      GenServer.cast(Stats, {:peer_left, self()})
      next_members = Map.delete(members, peer_id)

      if map_size(next_members) > 0 do
        send_peer_left(next_members, peer_id)
        {:ok, next_members}
      else
        GenServer.cast(Stats, {:room_closed, self()})
        {:stop, next_members}
      end
    else
      {:error, members}
    end
  end

  defp send_to_all(members, msg) do
    members
    |> Enum.each(fn {_, member} ->
      send(member.pid, {:to_user, msg})
    end)
  end

  defp send_joined_room(pid, own_id, members, turn_timeout) do
    now = System.os_time(:second)

    {turn_response, next_turn_timeout} =
      if System.get_env("SIGNALTOWER_TURN_SECRET") && turn_timeout < now do
        next_timeout = now + 3 * 60 * 60
        user = to_string(next_timeout) <> ":" <> own_id
        secret = System.get_env("SIGNALTOWER_TURN_SECRET")

        response = %{
          turn_user: user,
          turn_password:
            :crypto.mac(:hmac, :sha, to_charlist(secret), to_charlist(user)) |> Base.encode64()
        }

        {response, next_timeout}
      else
        {%{}, turn_timeout}
      end

    joined_response =
      Map.merge(turn_response, %{
        event: "joined_room",
        own_id: own_id,
        peers: members |> Map.values()
      })

    send(pid, {:to_user, joined_response})
    next_turn_timeout
  end

  defp send_new_peer(members, peer_id, status) do
    response_for_other_peers = %{
      event: "new_peer",
      peer_id: peer_id,
      status: status
    }

    send_to_all(members, response_for_other_peers)
  end

  defp send_peer_left(members, peer_id) do
    leave_msg = %{
      event: "peer_left",
      sender_id: peer_id
    }

    send_to_all(members, leave_msg)
  end
end

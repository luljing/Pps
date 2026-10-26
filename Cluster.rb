module VMS
  class Cluster
    attr_reader   :id
    attr_reader   :players
    attr_accessor :online_variables, :variables_dirty

    # [v4.163] 온라인 변수 표를 **바뀐 칸만** 보냅니다 (변경분 전송을 알린 클라이언트에게만. 옛 클라이언트는 예전처럼 표 전체).
    #   예전에는 표가 한 칸만 바뀌어도 서버가 표 전체(미니게임 중 3~12KB, 압축 후 2~5KB)를 매 틱 모두에게 보내서, 1000B 를 넘는
    #   덩어리는 조각으로 쪼개져 한 조각만 사라져도 통째로 버려졌고, 서버 PC 업로드도 초당 300KB 를 넘었습니다.
    #   - 바뀐 칸은 DELTA_REPEAT 번의 틱에 걸쳐 되풀이해 보냅니다. (UDP 는 가끔 사라지는데 칸 하나만 보내는 신호는 놓치면 그 값이 계속 낡음)
    #   - 그래도 놓친 것을 바로잡도록 VAR_SNAPSHOT_EVERY 초마다 표 전체를 한 번 보냅니다.
    #   - 클라이언트는 온라인 변수 CAPS_VAR_BASE + 자기 ID 를 1 로 올려 "변경분을 받을 수 있다" 고 알립니다 (게임 쪽 003_Board_VMS_Fixes.rb 와 같은 값).
    DELTA_REPEAT       = 3
    VAR_SNAPSHOT_EVERY = 2.0
    CAPS_VAR_BASE      = 4_000_000_000   # 플레이어 ID 는 몇 자리까지 갈지 몰라 아주 큰 값에서 시작
    CAPS_VAR_SPAN      = 4_000_000_000

    # 방 전체 정보(keyframe)를 접속 직후 2초·6초에 한 번씩, 그 뒤 30초마다 다시 보냅니다.
    # 첫 한 번을 놓쳐도(UDP 는 가끔 사라짐) 호스트가 영영 안 보이거나 파티가 옛 값으로 남지 않게 하는 안전장치입니다.
    KEYFRAME_FIRST_DELAY  = 2
    KEYFRAME_SECOND_DELAY = 4
    KEYFRAME_EVERY        = 30

    def initialize(id=-1, server=nil)
      @id = id
      @keyframes = {}
      @players = {}
      @online_variables = {}
      @variables_dirty = true
      @var_recent = {}
      @server = server
    end

    # 바뀐 칸을 알림 (서버 update 가 부름)
    def note_variable(key)
      @var_recent[key] = DELTA_REPEAT
      @variables_dirty = true
    end

    def add_player(player)
      @players[player.id] = player
      # 새로 들어온 사람은 변경분 전송 가능 여부를 처음부터 다시 알립니다 (같은 ID 로 다시 들어온 구판 클라이언트가
      # 지난 접속의 표시 때문에 변경분을 받는 일이 없게, 옛 표시는 지움)
      player.delta_caps = false
      player.var_snap_at = Time.now
      @online_variables.delete(CAPS_VAR_BASE + player.id.to_i)
      send_snapshot_to(player)
      @keyframes[player.id] = { n: 0, due: Time.now + KEYFRAME_FIRST_DELAY }
    end

    def send_snapshot_to(player)
      data = [[:online_variables, @online_variables]]
      @players.each_value { |p| data.push(p.full_hash) }
      binary = Zlib::Deflate.deflate(Marshal.dump(data), Config.compression_level)
      @server.send_binary(binary, player.address, player.port, player.socket)
    end

    def remove_player(player)
      id = player.is_a?(Player) ? player.id : player
      @players.delete(id)
      @keyframes.delete(id)

      @players.each_value do |p|
        @server.send([:disconnect_player, id], p.address, p.port, p.socket)
      end

      if @players.length == 0
        @server.remove_cluster(@id)
      end
    end

    def player_count
      return @players.length
    end

    def has_player(address, port)
      @players.each_value do |player|
        if player.address == address && player.port == port
          return true
        end
      end
      return false
    end

    def remove_player_by_address(address, port)
      @players.each_value do |player|
        if player.address == address && player.port == port
          remove_player(player.id)
          return true
        end
      end
      return false
    end

    def update_players
      @players.each_value do |player|
        if Time.now - player.last_seen > Config.heartbeat_timeout      # [v4.157] 서버가 마지막으로 패킷을 받은 때 기준 (클라이언트 시계와 무관)
          # [20261022] 왜 나갔는지 알 수 있게: 마지막 패킷이 온 지 얼마나 됐고 어디에 있었나 (server.log 에도 남음)
          place = (@server.place_label(player) rescue "?")
          @server.log("Player #{player.name} (#{player.id}) timed out. (방 #{@id} / #{place} / 마지막 패킷 #{(Time.now - player.last_seen).round(1)}초 전 / " \
                      "접속 중 가장 긴 간격 #{player.max_gap.round(1)}초)", true)
          remove_player(player)
        end
      end

      return if @players.empty?

      parts = @players.each_value.map { |player| player.to_hash(player.dirty) }
      capable, plain = @players.values.partition { |pl| pl.delta_caps? }

      # 옛 클라이언트: 예전처럼 표가 바뀐 틱에 표 전체
      unless plain.empty?
        data = []
        data.push([:online_variables, @online_variables]) if @variables_dirty
        data.concat(parts)
        binary = Zlib::Deflate.deflate(Marshal.dump(data), Config.compression_level)
        plain.each { |player| @server.send_binary(binary, player.address, player.port, player.socket) }
      end

      # 변경분 전송을 알린 클라이언트: 최근 DELTA_REPEAT 틱 안에 바뀐 칸만
      unless capable.empty?
        data = []
        unless @var_recent.empty?
          delta = {}
          @var_recent.each_key { |k| delta[k] = @online_variables[k] }
          data.push([:online_variables_delta, delta])
        end
        data.concat(parts)
        binary = Zlib::Deflate.deflate(Marshal.dump(data), Config.compression_level)
        capable.each { |player| @server.send_binary(binary, player.address, player.port, player.socket) }
      end

      @var_recent.keys.each do |k|
        @var_recent[k] -= 1
        @var_recent.delete(k) if @var_recent[k] <= 0
      end
      @players.each_value { |p| p.dirty = false }
      @variables_dirty = false

      now = Time.now
      @players.each_value do |p|
        k = @keyframes[p.id]
        next unless k && now >= k[:due]
        send_snapshot_to(p)
        k[:n] += 1
        k[:due] = now + (k[:n] == 1 ? KEYFRAME_SECOND_DELAY : KEYFRAME_EVERY)
        p.var_snap_at = now
      end

      # 변경분을 받는 클라이언트에게 표 전체를 VAR_SNAPSHOT_EVERY 초마다 (놓친 변경분 바로잡기. 플레이어 자료 없이 표만)
      snap = nil
      @players.each_value do |p|
        next unless p.delta_caps?
        next if p.var_snap_at && now - p.var_snap_at < VAR_SNAPSHOT_EVERY
        p.var_snap_at = now
        snap ||= Zlib::Deflate.deflate(Marshal.dump([[:online_variables, @online_variables]]), Config.compression_level)
        @server.send_binary(snap, p.address, p.port, p.socket)
      end
    end
  end
end

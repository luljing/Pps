
module VMS
  PACKET_KEYS = {
    id: 1, heartbeat: 2, name: 3, map_id: 4, x: 5, y: 6, real_x: 7, real_y: 8,
    trainer_type: 9, direction: 10, pattern: 11, graphic: 12, party: 13,
    animation: 14, offset_x: 15, offset_y: 16, opacity: 17, stop_animation: 18,
    rf_event: 19, jump_offset: 20, jumping_on_spot: 21, surfing: 22, diving: 23,
    surf_base_coords: 24, state: 25, busy: 26, cluster_id: 27,
    online_variables: 28, game_name: 29, game_version: 30, follower: 31,
    encounters: 32, encounter_claim: 33
  }
  REVERSE_KEYS = PACKET_KEYS.invert

  class Player
    attr_reader :id, :address, :port, :heartbeat, :dirty, :last_seen
    # [20261022] 타임아웃 기록용: 접속한 때, 접속 뒤 서버가 받은 패킷 사이의 가장 긴 간격(초)
    attr_reader :connected_at, :max_gap
    attr_accessor :socket, :name
    # [v4.163] 변경분 전송을 받을 수 있는 클라이언트인지 (온라인 변수 CAPS_VAR_BASE + 내 ID = 1 을 올린 클라이언트), 마지막 표 전체를 보낸 때
    attr_accessor :delta_caps, :var_snap_at

    def initialize(id, address, port)
      @id = id
      @address = address
      @port = port
      @heartbeat = Time.now
      @last_seen = Time.now   # [v4.157] 서버가 이 사람의 패킷을 마지막으로 받은 때 (서버 시계). 타임아웃은 이것으로 잼
      @connected_at = Time.now
      @max_gap = 0.0
      @client_hb = nil        # [v4.157] 클라이언트가 마지막으로 보낸 heartbeat (클라이언트 시계). 순서 비교는 이것끼리만
      @dirty = true
      @data = {}
      @dirty_fields = {}
    end

    # [20261022] 접속자가 지금 있는 맵 번호 (타임아웃 기록에서 로비 / 대기실 / 게임 중을 구분)
    def map_id
      return @data[PACKET_KEYS[:map_id]]
    end

    def delta_caps?
      return @delta_caps ? true : false
    end

    def update(data)
      # [v4.157] 시계가 서버와 다른 PC 의 접속 문제 수정.
      #   예전에는 클라이언트가 보낸 heartbeat(그 PC 의 시계)를 서버가 Player 를 만든 때의 Time.now(서버 시계)와 비교했습니다.
      #   클라이언트 시계가 서버보다 느리면 첫 갱신부터 이 줄에서 모두 버려져(맵·좌표가 한 번도 안 들어감 = 다른 사람에게 안 보임),
      #   heartbeat 도 안 바뀌어 30초 뒤 타임아웃으로 제거되고, 클라이언트는 모르고 계속 보내서 경고가 도배됐습니다. (제보 2026-10-18)
      #   반대로 시계가 빠르면 타임아웃 계산이 음수가 되어 끊긴 사람이 오래 남았습니다.
      #   이제 순서 비교는 같은 클라이언트가 보낸 값끼리만 하고(처음 값은 무조건 받음), 살아 있는지는 서버가 패킷을 받은 시각(@last_seen)으로 봅니다.
      #   @heartbeat 는 클라이언트가 보낸 값 그대로 둡니다(클라이언트가 핑을 자기 시계 값으로 재므로).
      # [20261022] 직전 패킷과의 간격 중 가장 긴 것을 적어 둠 (간격이 길었다 = 그 사람 PC 가 멈췄거나 길이 막혔던 것)
      now = Time.now
      gap = now - @last_seen
      @max_gap = gap if gap > @max_gap
      @last_seen = now    # 늦게 온(순서가 뒤바뀐) 패킷도 살아 있다는 증거라 비교보다 먼저 갱신
      hb_key = PACKET_KEYS[:heartbeat]
      if data[hb_key]
        return if @client_hb && data[hb_key] < @client_hb
        @client_hb = data[hb_key]
        @heartbeat = data[hb_key]
      end

      data.each do |k, v|
        next if k == hb_key
        next if @data.key?(k) && @data[k] == v
        @data[k] = v
        @dirty_fields[k] = true
      end
      @name = data[PACKET_KEYS[:name]] if data[PACKET_KEYS[:name]]
      @dirty = true unless @dirty_fields.empty?
    end

    def dirty=(value)
      @dirty = value
      @dirty_fields.clear unless value
    end

    def to_hash(full = true)
      hash = { PACKET_KEYS[:id] => @id, PACKET_KEYS[:heartbeat] => @heartbeat }
      return hash unless full
      @dirty_fields.each_key { |k| hash[k] = @data[k] }
      hash
    end

    def full_hash
      hash = { PACKET_KEYS[:id] => @id, PACKET_KEYS[:heartbeat] => @heartbeat }
      hash.merge!(@data)
      hash
    end
  end
end

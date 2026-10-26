class Pokemon
  class Move; end
  class Owner; end
end

module VMS
  require 'socket'
  require "zlib"
  require "openssl"
  require_relative 'Config'
  require_relative 'Frag'
  require_relative 'Cluster'
  require_relative 'Player'

  class GTS
    FILE_PATH = File.join(__dir__, "gts_listings.dat")

    attr_reader :load_error

    def initialize
      @mutex = Mutex.new
      @key = OpenSSL::Digest::SHA256.digest(Config.gts_encryption_key.to_s)
      @available = true
      @next_id = 1
      @records = []
      load_from_disk
    end

    def available?
      @available
    end

    def list_active
      @mutex.synchronize do
        @records.select { |r| r[:status] == :active }.map do |r|
          { id: r[:id], seller_id: r[:seller_id], seller_name: r[:seller_name], kind: r[:kind], summary: r[:summary], price: r[:price], preview: r[:preview] }
        end
      end
    end

    def peek(listing_id)
      return [false, "GTS is currently unavailable.", nil] unless @available
      @mutex.synchronize do
        record = @records.find { |r| r[:id] == listing_id }
        next [false, "That listing no longer exists.", nil] if record.nil?
        next [true, record[:payload], record[:kind]]
      end
    end

    def my_listings(player_id)
      @mutex.synchronize { @records.select { |r| r[:seller_id] == player_id }.map(&:dup) }
    end

    def create(kind, summary, payload, price, seller_id, seller_name, preview = nil)
      return [false, "GTS is currently unavailable."] unless @available
      return [false, "Invalid listing kind."] unless [:pokemon, :item].include?(kind)
      return [false, "Invalid price."] unless price.is_a?(Integer) && price > 0
      return [false, "Invalid summary."] unless summary.is_a?(String) && !summary.strip.empty?
      @mutex.synchronize do
        per_player = @records.count { |r| r[:seller_id] == seller_id && r[:status] == :active }
        if Config.gts_max_listings_per_player > 0 && per_player >= Config.gts_max_listings_per_player
          next [false, "You have reached the maximum number of active GTS listings."]
        end
        total_active = @records.count { |r| r[:status] == :active }
        if Config.gts_max_listings_total > 0 && total_active >= Config.gts_max_listings_total
          next [false, "The GTS is currently full."]
        end
        id = @next_id
        @next_id += 1
        @records.push({
          id: id, seller_id: seller_id, seller_name: seller_name.to_s,
          kind: kind, summary: summary.to_s, payload: payload, price: price,
          preview: preview, status: :active, buyer_id: nil, listed_at: Time.now, sold_at: nil
        })
        if save_to_disk
          next [true, id]
        else
          @records.pop
          @next_id -= 1
          next [false, "Failed to save the GTS listing."]
        end
      end
    end

    def claim(listing_id, buyer_id)
      return [false, "GTS is currently unavailable.", nil] unless @available
      @mutex.synchronize do
        record = @records.find { |r| r[:id] == listing_id }
        next [false, "That listing no longer exists.", nil] if record.nil?
        next [false, "That listing is no longer available.", nil] unless record[:status] == :active
        next [false, "You cannot claim your own listing.", nil] if record[:seller_id] == buyer_id
        previous_status = record[:status]
        record[:status]   = :sold
        record[:buyer_id] = buyer_id
        record[:sold_at]  = Time.now
        if save_to_disk
          next [true, record[:payload], record[:kind]]
        else
          record[:status]   = previous_status
          record[:buyer_id] = nil
          record[:sold_at]  = nil
          next [false, "Failed to save the GTS claim.", nil]
        end
      end
    end

    def collect(listing_id, seller_id)
      return [false, "GTS is currently unavailable."] unless @available
      @mutex.synchronize do
        record = @records.find { |r| r[:id] == listing_id }
        next [false, "That listing no longer exists."] if record.nil?
        next [false, "That listing does not belong to you."] unless record[:seller_id] == seller_id
        next [false, "That listing has not been sold yet."] unless record[:status] == :sold
        price = record[:price]
        @records.delete(record)
        if save_to_disk
          next [true, price]
        else
          @records.push(record)
          next [false, "Failed to save the GTS collection."]
        end
      end
    end

    def cancel(listing_id, seller_id)
      return [false, "GTS is currently unavailable.", nil] unless @available
      @mutex.synchronize do
        record = @records.find { |r| r[:id] == listing_id }
        next [false, "That listing no longer exists.", nil] if record.nil?
        next [false, "That listing does not belong to you.", nil] unless record[:seller_id] == seller_id
        next [false, "That listing is no longer active.", nil] unless record[:status] == :active
        @records.delete(record)
        if save_to_disk
          next [true, record[:payload], record[:kind]]
        else
          @records.push(record)
          next [false, "Failed to save the GTS cancellation.", nil]
        end
      end
    end

    private

    def load_from_disk
      return unless File.exist?(FILE_PATH)
      blob = File.binread(FILE_PATH)
      return if blob.nil? || blob.empty?
      @records = decrypt(blob)
      @next_id = (@records.map { |r| r[:id] }.max || 0) + 1
    rescue StandardError => e
      @available   = false
      @records     = []
      @load_error  = e.message
    end

    def save_to_disk
      File.binwrite(FILE_PATH, encrypt(@records))
      true
    rescue StandardError => e
      @load_error = e.message
      false
    end

    def encrypt(records)
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = @key
      iv = cipher.random_iv
      cipher.auth_data = ""
      ciphertext = cipher.update(Marshal.dump(records)) + cipher.final
      iv + cipher.auth_tag + ciphertext
    end

    def decrypt(blob)
      iv         = blob[0, 12]
      tag        = blob[12, 16]
      ciphertext = blob[28..-1] || ""
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = @key
      cipher.iv  = iv
      cipher.auth_tag  = tag
      cipher.auth_data = ""
      Marshal.load(cipher.update(ciphertext) + cipher.final)
    end
  end

  class Server
    attr_reader :socket
    attr_accessor :clusters

    def initialize
      if Config.use_tcp
        @socket = TCPServer.new(Config.host, Config.port)
      else
        @socket = UDPSocket.new
        @socket.bind(Config.host, Config.port)
      end
      @clients = {}
      @clusters = {}
      @gts = GTS.new
      log("GTS store failed to load and has been disabled: #{@gts.load_error}", true) unless @gts.available?
      begin
        run
      rescue Interrupt
        log("Server has been stopped by the user.")
      rescue => e
        log("Server stopped with error: #{e}", true)
      end
    end

    def run
      log("Server started on #{Config.host}:#{Config.port}.")
      log("서버 20261022: 연결 끊김 알림 정리 + server.log 기록 + 타임아웃 상세")
      tune_windows

      tick_interval = Config.tick_rate > 0 ? 1.0 / Config.tick_rate.to_f : 0.0
      last_tick = Time.now
      stats_reset(Time.now)

      loop do
        wait_time = nil
        if tick_interval > 0
          now = Time.now
          elapsed = now - last_tick
          wait_time = [tick_interval - elapsed, 0].max
        end

        readable, = IO.select([@socket] + @clients.values, nil, nil, wait_time)

        if readable
          readable.each do |s|
            if s == @socket && Config.use_tcp
              begin
                client = @socket.accept_nonblock
                @clients[client.addr] = client
                log("New client connected: #{client.addr}")
              rescue IO::WaitReadable, IO::WaitWritable
              end
            else
              begin
                if Config.use_tcp
                  data = s.respond_to?(:recv_nonblock) ? s.recv_nonblock(65536) : s.recv(65536)
                  handle_packet(data, s.addr[3], s.addr[1], s)
                else
                  data, address = @socket.respond_to?(:recvfrom_nonblock) ? @socket.recvfrom_nonblock(65536) : @socket.recvfrom(65536)
                  # 큰 덩어리는 조각으로 오므로 다 모일 때까지 붙입니다 (Frag.rb)
                  @frag_rx ||= {}
                  data = Frag.feed(@frag_rx, [address[3], address[1]], data)
                  handle_packet(data, address[3], address[1]) if data
                end
              rescue EOFError
                log("Client disconnected: #{s.addr}")
                @clients.delete(s.addr)
                s.close
              rescue IO::WaitReadable, IO::WaitWritable
              rescue Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ECONNABORTED => e
                # [20261022] 윈도우는 UDP 로 보낸 상대 포트가 닫혀 있으면(접속자 연결·터널이 끊김) 그 다음 recvfrom 에서 이 오류를 냅니다.
                #   끊긴 사람에게 매 틱 보내는 동안 줄마다 찍으면 콘솔이 도배돼 서버 루프가 느려지므로 세기만 하고 요약합니다.
                if Config.use_tcp
                  log("Error receiving data: #{e}", true)
                else
                  note_conn_reset
                end
              rescue => e
                log("Error receiving data: #{e}", true)
              end
            end
          end
        end

        if tick_interval == 0 || (Time.now - last_tick) >= tick_interval
          # [v4.130] 측정: 틱이 예정보다 얼마나 늦었나 / 갱신 처리에 얼마나 걸렸나 (동작에는 영향 없음)
          tick_start = Time.now
          if tick_interval > 0
            late = (tick_start - last_tick) - tick_interval
            @stat_late_max = late if late > @stat_late_max
            @stat_late_n += 1 if late > 0.05
            # [v4.149] 서버가 1초 넘게 멈췄다 풀리면 그때 바로 파일에 남깁니다 (콘솔 창 선택 멈춤·PC 과부하 확인용)
            if late > 1.0
              log("서버 루프가 #{late.round(1)}초 멈췄다가 풀렸습니다", true)
              stats_file_log("멈춤: 틱이 #{late.round(1)}초 늦음 (접속 #{@clusters.values.sum { |c| c.player_count }}명)")
            end
          end
          @clusters.each_value do |cluster|
            begin
              cluster.update_players
            rescue => e
              log("Error updating cluster #{cluster.id}: #{e}", true)
            end
          end
          last_tick = Time.now
          took = last_tick - tick_start
          @stat_upd_max = took if took > @stat_upd_max
          @stat_ticks += 1
          stats_report(last_tick)
        end
      end
    end

    def handle_packet(data, address, port, socket = nil)
      return if data.nil? || data.empty?
      begin
        data = Marshal.load(Zlib::Inflate.inflate(data))
        return unless data.is_a?(Array)
        return unless data.length >= 2 || (data.length >= 1 && ["list_clusters", "gts_list"].include?(data[0]))

        case data[0]
        when "connect"      then connect(address, port, sanitize_data(data[1]), socket)
        when "disconnect"   then disconnect(address, port, sanitize_data(data[1]), socket)
        when "update"       then update(address, port, sanitize_data(data[1]), socket)
        when "list_clusters" then list_clusters(address, port, socket)
        when "chat"         then chat(address, port, sanitize_data(data[1]), socket)
        when "gts_list"         then gts_list(address, port, socket)
        when "gts_create"       then gts_create(address, port, data[1], socket)
        when "gts_claim"        then gts_claim(address, port, data[1], socket)
        when "gts_my_listings"  then gts_my_listings(address, port, data[1], socket)
        when "gts_collect"      then gts_collect(address, port, data[1], socket)
        when "gts_cancel"       then gts_cancel(address, port, data[1], socket)
        when "gts_peek"         then gts_peek(address, port, data[1], socket)
        end
      rescue => e
        log("Packet error from #{address}:#{port} - #{e}", true)
      end
    end

    def sanitize_data(data)
      return {} unless data.is_a?(Hash)
      sanitized = {}
      expected = {
        PACKET_KEYS[:id] => Integer,
        PACKET_KEYS[:cluster_id] => Integer,
        PACKET_KEYS[:name] => String,
        PACKET_KEYS[:map_id] => Integer,
        PACKET_KEYS[:x] => Integer,
        PACKET_KEYS[:y] => Integer,
        PACKET_KEYS[:real_x] => Numeric,
        PACKET_KEYS[:real_y] => Numeric,
        PACKET_KEYS[:direction] => Integer,
        PACKET_KEYS[:pattern] => Integer,
        PACKET_KEYS[:graphic] => String,
        PACKET_KEYS[:heartbeat] => Time
      }

      data.each do |k, v|
        key = k
        if k.is_a?(String) || k.is_a?(Symbol)
          key = PACKET_KEYS[k.to_sym] || k
        end

        if expected.key?(key)
          if v.is_a?(expected[key])
            sanitized[key] = v
          elsif expected[key] == Integer && v.respond_to?(:to_i)
            sanitized[key] = v.to_i
          elsif expected[key] == Numeric && v.respond_to?(:to_f)
            sanitized[key] = v.to_f
          elsif expected[key] == String
            sanitized[key] = v.to_s
          end
        else
          sanitized[key] = v
        end
      end
      sanitized
    end

    def connect(address, port, data, socket = nil)
      if Config.check_game_and_version
        if data[PACKET_KEYS[:game_name]] != Config.game_name
          log("#{get_player_name(data)} (#{address}:#{port}) 접속 거절: 게임 이름이 다릅니다 (받은 값 #{data[PACKET_KEYS[:game_name]].inspect} / 서버 설정 #{Config.game_name.inspect})", true)
          send(:disconnect_wrong_game, address, port, socket)
          return
        end
        if data[PACKET_KEYS[:game_version]] != Config.game_version
          log("#{get_player_name(data)} (#{address}:#{port}) 접속 거절: 게임 판이 다릅니다 (받은 값 #{data[PACKET_KEYS[:game_version]].inspect} / 서버 설정 #{Config.game_version.inspect})", true)
          send(:disconnect_wrong_version, address, port, socket)
          return
        end
      end
      @stray.delete([address, port]) if @stray    # [v4.157] 다시 접속했으니 방에 없는 사람으로 세던 기록 지움
      player = Player.new(data[PACKET_KEYS[:id]], address, port)
      player.socket = socket

      cluster_id = data[PACKET_KEYS[:cluster_id]] || 0
      if cluster_exists(cluster_id)
        cluster = @clusters.values.find { |c| c.id == cluster_id }
        if cluster.player_count < Config.max_players
          cluster.add_player(player)
          player.update(data)
          log("#{get_player_name(data)} connected to cluster #{cluster_id}.")
        else
          log("#{get_player_name(data)} tried to connect to cluster #{cluster_id}, but it was full. (#{cluster.player_count}/#{Config.max_players}명) -> disconnect_full", true)
          send(:disconnect_full, address, port, socket)
        end
      elsif Config.max_clusters > 0 && @clusters.length >= Config.max_clusters
        log("#{get_player_name(data)} tried to create cluster #{cluster_id}, but the server has reached its maximum of #{Config.max_clusters} clusters.", true)
        send(:disconnect_full, address, port, socket)
      else
        cluster = Cluster.new(cluster_id, self)
        @clusters[cluster_id] = cluster
        cluster.add_player(player)
        player.update(data)
        log("#{get_player_name(data)} connected to newly created cluster #{cluster_id}.")
      end
    end

    def disconnect(address, port, data, socket = nil)
      cluster_id = data[PACKET_KEYS[:cluster_id]]
      if cluster_exists(cluster_id)
        cluster = @clusters.values.find { |c| c.id == cluster_id }
        if cluster.has_player(address, port)
          cluster.remove_player(data[PACKET_KEYS[:id]])
          log("#{get_player_name(data)} disconnected from cluster #{cluster_id}.")
        else
          log("#{get_player_name(data)} tried to disconnect from cluster #{cluster_id}, but they weren't connected.")
        end
      else
        log("#{get_player_name(data)} tried to disconnect from cluster #{cluster_id}, but it didn't exist.")
      end
      send(:disconnect, address, port, socket)
    end

    def update(address, port, data, socket = nil)
      cluster_id = data[PACKET_KEYS[:cluster_id]]
      if cluster_exists(cluster_id)
        cluster = @clusters.values.find { |c| c.id == cluster_id }
        if cluster.has_player(address, port)
          ov_key = PACKET_KEYS[:online_variables]
          if !data[ov_key].nil?
            data[ov_key].each do |key, value|
              # [v4.163] 변경분 전송을 받을 수 있다고 알리는 칸 (CAPS_VAR_BASE + 그 사람 ID = 1)
              if key.is_a?(Integer) && key >= Cluster::CAPS_VAR_BASE && key < Cluster::CAPS_VAR_BASE + Cluster::CAPS_VAR_SPAN
                capper = cluster.players[key - Cluster::CAPS_VAR_BASE]
                capper.delta_caps = (value == 1) if capper
              end
              next if cluster.online_variables[key] == value
              # [v4.100] 이 줄을 없앴습니다. 미니게임 중에는 초당 수십 번 불리는데, 값(표·파티 자료)을 글자로 펼치고
              #   콘솔에 쓰는 일이 서버 한 줄 루프를 붙잡아 모두의 지연을 키웠습니다. 값은 찍지 않고 키만 필요할 때 켜세요.
              #   log("#{get_player_name(data)} updated online variable #{key}.") if Config.log_variables
              cluster.online_variables[key] = value
              cluster.note_variable(key)
            end
          end
          cluster.players[data[PACKET_KEYS[:id]]].update(data)
          cluster.players[data[PACKET_KEYS[:id]]].socket = socket if socket
        else
          stray_update(address, port, data, cluster_id, "they weren't connected", socket)
        end
      else
        stray_update(address, port, data, cluster_id, "it didn't exist", socket)
      end
    end

    # [v4.157] 방에 없는 사람(타임아웃으로 제거됐거나, 서버가 다시 켜졌거나, 접속 패킷을 놓침)의 갱신 처리.
    #   예전에는 패킷마다 경고를 찍어 콘솔이 도배됐고(그 직전의 "timed out" 로그를 찾을 수 없었음), 클라이언트는 끊긴 줄 모르고 계속 보냈습니다.
    #   - 경고는 주소마다 STRAY_LOG_EVERY 초에 한 번, 그동안 생략한 수를 같이 적음. server_stats.log 에도 남김.
    #   - 3초 넘게 계속 보내면 STRAY_REPLY_EVERY 초에 한 번 :disconnect 를 돌려보내 클라이언트가 끊긴 걸 알게 함
    #     (접속 패킷이 조금 늦게 오는 정상 경우를 건드리지 않으려고 3초 기다림. 접속하면 기록을 지움)
    STRAY_LOG_EVERY   = 10.0
    STRAY_REPLY_AFTER = 3.0
    STRAY_REPLY_EVERY = 1.0

    def stray_update(address, port, data, cluster_id, reason, socket = nil)
      @stray ||= {}
      now = Time.now
      st = (@stray[[address, port]] ||= { first: now, log_at: nil, reply_at: nil, hidden: 0 })
      if st[:log_at].nil? || now - st[:log_at] >= STRAY_LOG_EVERY
        extra = st[:hidden] > 0 ? " (같은 주소의 경고 #{st[:hidden]}번 생략)" : ""
        line = "#{get_player_name(data)} (#{address}:#{port}) tried to update cluster #{cluster_id}, but #{reason}.#{extra}"
        log(line, true)
        stats_file_log("경고: #{line}")
        st[:log_at] = now
        st[:hidden] = 0
      else
        st[:hidden] += 1
      end
      if now - st[:first] >= STRAY_REPLY_AFTER && (st[:reply_at].nil? || now - st[:reply_at] >= STRAY_REPLY_EVERY)
        st[:reply_at] = now
        send(:disconnect, address, port, socket)
      end
      # 오래된 기록 정리 (5분 넘게 조용한 주소)
      if @stray.length > 64
        @stray.delete_if { |_, v| now - (v[:reply_at] || v[:log_at] || v[:first]) > 300 }
      end
    end

    MAX_CHAT_MESSAGE_LENGTH = 500

    def chat(address, port, data, socket = nil)
      cluster_id = data[PACKET_KEYS[:cluster_id]]
      return unless cluster_exists(cluster_id)
      cluster = @clusters.values.find { |c| c.id == cluster_id }
      return unless cluster.has_player(address, port)
      sender = cluster.players[data[PACKET_KEYS[:id]]]
      return if sender.nil?
      text = data[:text].to_s.strip
      return if text.empty?
      text = text[0, MAX_CHAT_MESSAGE_LENGTH]
      log("#{sender.name} (#{sender.id}) chat: #{text}")
      cluster.players.each_value do |p|
        next if p.id == sender.id
        send([:chat, sender.id, sender.name, text], p.address, p.port, p.socket)
      end
    end

    def send(data, address, port, socket = nil)
      binary = Zlib::Deflate.deflate(Marshal.dump(data), Config.compression_level)
      send_binary(binary, address, port, socket)
    end

    def send_binary(binary, address, port, socket = nil)
      if Config.use_tcp
        target = socket || @clients.values.find { |c| c.addr[3] == address && c.addr[1] == port }
        if target
          begin
            target.write([binary.bytesize].pack("N") + binary)
          rescue => e
            log("TCP Send Error to #{address}:#{port} - #{e}")
            @clients.delete(target.addr)
            @clusters.each_value { |c| c.remove_player_by_address(address, port) }
          end
        end
      else
        begin
          # 1200바이트를 넘으면 1000바이트 조각으로 쪼개 보냅니다 (Frag.rb)
          @frag_tx = ((@frag_tx || rand(0x100000000)) + 1) & 0xFFFFFFFF
          parts = Frag.split(binary, @frag_tx)
          if parts.length > 1
            @frag_logged = (@frag_logged || 0) + 1
            log("Large packet #{binary.bytesize} bytes -> #{parts.length} parts to #{address}:#{port}") if @frag_logged <= 10
          end
          @stat_pkts += parts.length
          @stat_bytes += binary.bytesize
          @stat_big = binary.bytesize if binary.bytesize > @stat_big
          parts.each { |pkt| @socket.send(pkt, 0, address, port) }
        rescue => e
          log("UDP Send Error to #{address}:#{port} - #{e}")
        end
      end
    end

    # [v4.130] 10초마다 한 줄 (지연이 서버 때문인지 가리려는 측정)
    #   늦음 = 틱이 예정 시각보다 얼마나 늦게 돌았나. 이게 크면 서버 PC·루프가 밀린 것입니다.
    #   보낸 양 = 압축된 덩어리 크기 합(조각 머리 제외). 표(온라인 변수)는 바뀔 때마다 통째로 나가므로 가장 큰 덩어리가 곧 표 크기.
    # [v4.149] 윈도우 서버 PC 보정.
    #   1) 타이머 정밀도: 윈도우는 대기(sleep/select)를 15.6ms 단위로 올려서, tick_rate = 30(33.3ms)이 실제로는 46.9ms(약 22Hz)로 돌았습니다.
    #      (이 서버의 루비로 재 보니 33ms 대기가 평균 45.6ms, timeBeginPeriod(1) 뒤에는 34.3ms. 클라이언트 로그의 "도착 간격 평균 46ms" 와 같음)
    #   2) 콘솔 빠른 편집(QuickEdit): 콘솔 창을 클릭하거나 글자를 선택하면 프로그램이 멈춥니다. 서버가 멈추면 접속자는 30초 뒤 연결이 끊깁니다.
    #      끄면 마우스로 글자를 선택해 복사할 수 없게 됩니다(필요하면 config.ini 에 windows_tuning = false).
    #   실패해도 서버는 그대로 돕니다(알림만 남김). 끝낼 때 되돌리는 것은 프로세스가 끝나면 윈도우가 알아서 합니다.
    def tune_windows
      return unless Config.windows_tuning
      return unless RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin/
      notes = []
      begin
        saved = $VERBOSE
        begin
          $VERBOSE = nil
          require "fiddle"
        ensure
          $VERBOSE = saved
        end
      rescue StandardError, LoadError => e
        log("[보정] fiddle 을 못 불러 건너뜁니다 (#{e.class})", true)
        return
      end
      begin
        winmm = Fiddle.dlopen("winmm.dll")
        begin_period = Fiddle::Function.new(winmm["timeBeginPeriod"], [Fiddle::TYPE_UINT], Fiddle::TYPE_UINT)
        notes << (begin_period.call(1) == 0 ? "타이머 정밀도 1ms" : "타이머 정밀도 변경 실패")
      rescue StandardError, LoadError => e
        notes << "타이머 정밀도 변경 못 함(#{e.class})"
      end
      # [v4.162] 윈도우 11 은 창이 가려지거나 최소화된 프로세스의 타이머 정밀도 요청(timeBeginPeriod)을 무시할 수 있습니다.
      #   그러면 틱이 초당 28.9 에서 21.9 로 떨어졌다 돌아왔다 했습니다(2026-10-19 서버 통계, 15.6ms 타이머 3칸).
      #   "타이머 해상도 요청 무시" 절전 규칙(ProcessPowerThrottling / IGNORE_TIMER_RESOLUTION)을 이 프로세스에서 끕니다.
      #   구형 윈도우에는 이 함수가 없을 수 있어(못 찾으면) 건너뜁니다.
      begin
        k32 = Fiddle.dlopen("kernel32.dll")
        get_proc = Fiddle::Function.new(k32["GetCurrentProcess"], [], Fiddle::TYPE_VOIDP)
        set_info = Fiddle::Function.new(k32["SetProcessInformation"],
                                        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        state = Fiddle::Pointer.malloc(12)
        state[0, 12] = [1, 4, 0].pack("LLL")      # Version 1 / ControlMask IGNORE_TIMER_RESOLUTION(4) / StateMask 0 = 끔
        notes << (set_info.call(get_proc.call, 4, state, 12) != 0 ? "타이머 절전 해제" : "타이머 절전 해제 실패")
      rescue StandardError, LoadError => e
        notes << "타이머 절전 해제 못 함(#{e.class})"
      end
      begin
        kernel32 = Fiddle.dlopen("kernel32.dll")
        get_std  = Fiddle::Function.new(kernel32["GetStdHandle"], [Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
        get_mode = Fiddle::Function.new(kernel32["GetConsoleMode"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
        set_mode = Fiddle::Function.new(kernel32["SetConsoleMode"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        handle = get_std.call(-10)                 # STD_INPUT_HANDLE
        buf = Fiddle::Pointer.malloc(4)
        if get_mode.call(handle, buf) != 0
          mode = buf[0, 4].unpack1("L")
          fixed = (mode | 0x0080) & ~0x0040        # ENABLE_EXTENDED_FLAGS 켜고 ENABLE_QUICK_EDIT_MODE 끔
          notes << (set_mode.call(handle, fixed) != 0 ? "콘솔 선택 멈춤 방지" : "콘솔 설정 변경 실패")
        else
          notes << "콘솔 아님(건너뜀)"
        end
      rescue StandardError, LoadError => e
        notes << "콘솔 설정 못 함(#{e.class})"
      end
      log("[보정] #{notes.join(' / ')}")
      stats_file_log("[보정] #{notes.join(' / ')}")
    end

    STATS_FILE = File.join(__dir__, "server_stats.log")

    # [v4.149] 통계·멈춤을 파일에도 남깁니다(콘솔은 창을 닫으면 사라짐). 1MB 가 넘으면 .old 로 넘기고 새로 씁니다.
    def stats_file_log(text)
      if File.exist?(STATS_FILE) && File.size(STATS_FILE) > 1_000_000
        old = STATS_FILE + ".old"
        File.delete(old) if File.exist?(old)
        File.rename(STATS_FILE, old)
      end
      File.open(STATS_FILE, "a") { |f| f.puts("#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} #{text}") }
    rescue StandardError
    end

    def stats_reset(now)
      @stat_t0 = now
      @stat_ticks = 0
      @stat_late_max = 0.0
      @stat_late_n = 0
      @stat_upd_max = 0.0
      @stat_pkts = 0
      @stat_bytes = 0
      @stat_big = 0
      @stat_reset = 0
    end

    # [v4.133] 10초마다였던 것을 60초마다로, 접속자가 없으면 아예 안 찍음(콘솔이 통계로 도배되던 것).
    #   서버가 밀린 구간(틱이 50ms 넘게 늦음)이 있으면 예전처럼 경고 색으로 찍음. 그 구간도 60초에 한 번이면 충분(최대값이 줄에 들어감).
    STATS_INTERVAL = 60.0

    def stats_report(now)
      return if now - @stat_t0 < STATS_INTERVAL
      secs = now - @stat_t0
      players = @clusters.values.sum { |c| c.player_count }
      bad = @stat_late_n > 0
      if players == 0 && !bad
        stats_reset(now)
        return
      end
      line = "[통계] #{secs.round}초: 틱 #{@stat_ticks}회(초당 #{(@stat_ticks / secs).round(1)}), 늦음 최대 #{(@stat_late_max * 1000).round}ms (50ms 초과 #{@stat_late_n}회), " \
             "갱신 처리 최대 #{(@stat_upd_max * 1000).round}ms, 보낸 패킷 #{@stat_pkts}개 #{(@stat_bytes / 1024.0).round}KB " \
             "(초당 #{(@stat_bytes / 1024.0 / secs).round(1)}KB, 가장 큰 덩어리 #{@stat_big}B), 접속 #{players}명 / 방 #{@clusters.length}개"
      line += ", 끊긴 접속자 알림 #{@stat_reset}회" if @stat_reset.to_i > 0
      log(line, bad)
      stats_file_log(line)
      stats_reset(now)
    end

    def log(message="", warning=false)
      puts "\e[34m[\e[36m#{Time.now.strftime("%d/%m/%Y - %H:%M:%S")}\e[34m] #{warning ? "\e[31mWARNING: " : "\e[1m\e[36m"}#{message}\e[0m" if Config.log
      file_log("#{warning ? '!! ' : ''}#{message}")
    end

    # [20261022] 화면에 찍는 기록을 server.log 에도 남깁니다. 접속·타임아웃·방 닫힘이 화면에만 있으면 창을 닫거나 서버를 다시 켜면 사라져서
    #   "왜 튕겼나" 를 나중에 알 수 없었습니다. 2MB 가 넘으면 .old 로 넘기고 새로 씁니다. 파일을 못 써도 서버는 그대로 돕니다.
    LOG_FILE     = File.join(__dir__, "server.log")
    LOG_FILE_MAX = 2_000_000

    def file_log(text)
      @file_log_n = (@file_log_n || 0) + 1
      rotate_file_log if @log_io.nil? || @log_io.closed? || (@file_log_n % 200).zero?
      @log_io.puts("#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} #{text.to_s.gsub(/\s*[\r\n]+\s*/, ' ')}") if @log_io
    rescue StandardError
      @log_io = nil
    end

    def rotate_file_log
      if File.exist?(LOG_FILE) && File.size(LOG_FILE) > LOG_FILE_MAX
        @log_io.close if @log_io && !@log_io.closed?
        @log_io = nil
        old = LOG_FILE + ".old"
        File.delete(old) if File.exist?(old)
        File.rename(LOG_FILE, old)
      end
      if @log_io.nil? || @log_io.closed?
        @log_io = File.open(LOG_FILE, "a:UTF-8")
        @log_io.sync = true
      end
    end

    # [20261022] 끊긴 접속자에게 보낸 패킷이 되돌아왔다는 알림(윈도우 ECONNRESET)을 세고, 10초에 한 번만 요약해 알립니다.
    CONN_RESET_LOG_EVERY = 10.0

    def note_conn_reset
      @stat_reset = @stat_reset.to_i + 1
      @reset_pending = @reset_pending.to_i + 1
      now = Time.now
      return if @reset_log_at && now - @reset_log_at < CONN_RESET_LOG_EVERY
      since = @reset_log_at ? "최근 #{(now - @reset_log_at).round}초 동안 #{@reset_pending}번" : "처음 감지"
      log("끊긴 접속자에게 보낸 패킷이 되돌아왔습니다 (#{since}). 그 사람의 연결(터널)이 끊긴 것이며, 응답이 없으면 곧 자동으로 정리됩니다.", true)
      @reset_log_at = now
      @reset_pending = 0
    end

    # [20261022] 접속자가 있는 곳 (타임아웃 기록용). 맵 번호는 게임의 로비 / 대기실 맵과 같게 유지.
    LOBBY_MAPS   = [3].freeze
    WAITING_MAPS = [4].freeze

    def place_label(pl)
      map = pl.map_id
      return "맵 ?" if map.nil?
      return "로비" if LOBBY_MAPS.include?(map)
      return "대기실" if WAITING_MAPS.include?(map)
      return "게임 중(맵 #{map})"
    end

    def get_player_name(data)
      return data[PACKET_KEYS[:name]] || "Unknown Player"
    end

    def cluster_exists(id)
      @clusters.each_value do |cluster|
        if cluster.id == id
          return true
        end
      end
      return false
    end

    def remove_cluster(id)
      @clusters.delete(id)
      log("방 #{id} 이(가) 비어서 닫혔습니다. (남은 방 #{@clusters.length}개)")
    end

    def list_clusters(address, port, socket = nil)
      cluster_list = []
      @clusters.each_value do |cluster|
        cluster_list.push({
          id: cluster.id,
          player_count: cluster.player_count,
          max_players: Config.max_players     # 방 찾기 목록에 "(1/8)" 처럼 보이게 (v4.105)
        })
      end
      send([:cluster_list, cluster_list], address, port, socket)
      log("Sent cluster list to #{address}:#{port}")
    end

    def gts_list(address, port, socket = nil)
      send([:gts_list_result, @gts.list_active], address, port, socket)
    end

    def gts_create(address, port, data, socket = nil)
      return unless data.is_a?(Array) && data.length >= 6
      kind, summary, payload, price, seller_id, seller_name, preview = data
      success, id_or_reason = @gts.create(kind, summary, payload, price, seller_id, seller_name, preview)
      send([:gts_create_result, success, id_or_reason], address, port, socket)
      log("#{seller_name} listed \"#{summary}\" on the GTS for #{price}.") if success
    end

    def gts_claim(address, port, data, socket = nil)
      return unless data.is_a?(Array) && data.length >= 2
      listing_id, buyer_id = data
      success, payload_or_reason, kind = @gts.claim(listing_id, buyer_id)
      send([:gts_claim_result, success, payload_or_reason, kind], address, port, socket)
    end

    def gts_my_listings(address, port, data, socket = nil)
      player_id = data.is_a?(Array) ? data[0] : data
      send([:gts_my_listings_result, @gts.my_listings(player_id)], address, port, socket)
    end

    def gts_collect(address, port, data, socket = nil)
      return unless data.is_a?(Array) && data.length >= 2
      listing_id, seller_id = data
      success, price_or_reason = @gts.collect(listing_id, seller_id)
      send([:gts_collect_result, success, price_or_reason], address, port, socket)
    end

    def gts_cancel(address, port, data, socket = nil)
      return unless data.is_a?(Array) && data.length >= 2
      listing_id, seller_id = data
      success, payload_or_reason, kind = @gts.cancel(listing_id, seller_id)
      send([:gts_cancel_result, success, payload_or_reason, kind], address, port, socket)
    end

    def gts_peek(address, port, data, socket = nil)
      return unless data.is_a?(Array) && data.length >= 1
      listing_id = data[0]
      success, payload_or_reason, kind = @gts.peek(listing_id)
      send([:gts_peek_result, success, payload_or_reason, kind], address, port, socket)
    end
  end

  Server.new
end
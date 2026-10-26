# UDP 큰 덩어리 쪼개기 / 붙이기 (v4.84)
#
# 왜: 포켓몬 파티·교환 자료처럼 큰 덩어리(수 KB)를 UDP 한 번에 보내면 인터넷(특히 playit 같은 중계)이
#     약 1.4KB 넘는 것을 버려서 상대에게 안 갑니다. 그래서 1000바이트 조각으로 나눠 보내고 받는 쪽이 붙입니다.
# 형식: [0xFD, 덩어리 번호(4바이트), 몇 번째(2바이트), 모두 몇 개(2바이트)] + 조각.
#       원래 덩어리는 zlib 이라 첫 바이트가 0x78 -> 0xFD 와 겹치지 않아 작은 덩어리는 그대로 보냅니다.
# 클라이언트 쪽 같은 규칙: 게임의 Plugins/_Pokemon Party/007_Multiplayer/000_Board_UDP_Frag.rb
#   (두 곳의 상수·형식을 바꿀 때는 반드시 함께 바꿀 것)
module VMS
  module Frag
    MAGIC       = 0xFD
    LIMIT       = 1200    # 이 크기 이하는 쪼개지 않음
    PAYLOAD     = 1000    # 조각 하나의 내용 크기
    MAX_PARTS   = 512     # 한 덩어리 최대 조각 수 (약 500KB)
    MAX_PENDING = 64      # 붙이는 중인 덩어리 최대 수 (넘으면 가장 오래된 것부터 버림)
    EXPIRE      = 10.0    # 이 시간 안에 다 못 모으면 버림 (초)
    HEADER      = "CNnn"
    HEADER_SIZE = 9

    def self.now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # 보낼 덩어리 -> 보낼 조각 목록 (작으면 그대로 한 개)
    def self.split(data, id)
      return [data] if data.bytesize <= LIMIT
      bytes = data.b
      count = (bytes.bytesize + PAYLOAD - 1) / PAYLOAD
      return [data] if count > MAX_PARTS
      parts = []
      count.times do |i|
        parts << ([MAGIC, id & 0xFFFFFFFF, i, count].pack(HEADER) + bytes.byteslice(i * PAYLOAD, PAYLOAD))
      end
      parts
    end

    # 받은 한 개 -> 쪼개진 것이 아니면 그대로, 조각이면 다 모였을 때만 원래 덩어리, 아직이면 nil
    # pending: 받는 쪽이 들고 있는 Hash, who: 보낸 쪽을 가르는 열쇠 (서버는 [주소, 포트], 클라이언트는 아무 값)
    def self.feed(pending, who, data)
      return data unless data.is_a?(String) && data.getbyte(0) == MAGIC
      return nil if data.bytesize <= HEADER_SIZE
      _magic, id, idx, count = data.unpack(HEADER)
      return nil if count.nil? || count < 1 || count > MAX_PARTS || idx >= count
      t = now
      sweep(pending, t)
      key = [who, id]
      entry = pending[key]
      if entry.nil?
        if pending.size >= MAX_PENDING
          oldest = pending.min_by { |_k, v| v[:t] }
          pending.delete(oldest[0]) if oldest
        end
        entry = pending[key] = { count: count, parts: {}, t: t }
      end
      return nil if entry[:count] != count
      entry[:parts][idx] = data.byteslice(HEADER_SIZE, data.bytesize - HEADER_SIZE)
      entry[:t] = t
      return nil if entry[:parts].size < count
      pending.delete(key)
      whole = String.new(encoding: Encoding::BINARY)
      count.times { |i| whole << entry[:parts][i] }
      whole
    end

    def self.sweep(pending, t = now)
      return if pending.empty?
      pending.delete_if { |_k, v| t - v[:t] > EXPIRE }
    end
  end
end

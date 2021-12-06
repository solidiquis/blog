require "ostruct"
require "socket"

class ThreadPool
  DEFAULT_SIZE = 4

  attr_reader :workers

  class AllWorkersBusy < StandardError; end

  def initialize(size)
    @workers = (0...size).map { |i| Worker.new id: i }
  end

  def handle_client(&handler)
    loop do
      worker = workers.find { |w| w.ready? } or raise AllWorkersBusy
      worker.run handler
      break
    rescue AllWorkersBusy
      sleep 0.1
    end

    true
  end

  def shutdown
    puts "Waiting for all workers to complete current jobs..."
    until workers.all?(&:ready?)
      sleep 0.1 
    end
    puts "Shutting down workers..."
    @workers.each(&:terminate)
  end

  class Worker
    STATES = OpenStruct.new(
      ready: "ready",
      working: "working",
    ).freeze

    STATES.to_h.each do |_, v|
      define_method("#{v}?") { state == v }
    end

    attr_reader :id, :state

    def initialize(id:)
      @id = id
      @state = STATES.ready
      @job = nil
      @thread = Thread.new do
        loop do
          Thread.stop
          @job.call
        rescue IOError => e
          puts e.message
        ensure
          @state = STATES.ready
          @job = nil
        end
      end
    end

    def run(job)
      @state = STATES.working
      @job = job
      @thread.run
    end

    def terminate
      @thread.terminate
    end
  end
end

if __FILE__ == $0
  server = TCPServer.new 8080
  pool = ThreadPool.new ThreadPool::DEFAULT_SIZE

  Signal.trap("INT") do
    begin
      server.close
    rescue IOError
      puts "Gracefully shutting down..."
    end
    pool.shutdown

    exit 0
  end

  server.listen(20)

  loop do
    conn = server.accept
    pool.handle_client do
      sleep 2
      conn.write conn.recv(1024)
      conn.close
    end
  end
end

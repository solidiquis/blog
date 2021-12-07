# Concurrency in Ruby
There is a surprising number of people (seasoned Rubyists included), who are unclear on the subject of concurrency in the official Ruby implementation which runs on the *Yet another Ruby Virtual Machine*, or YARV for brevity. You often hear folks invoking the Global Interpreter Lock (GIL)—though it's more correctly referred to as the Global VM Lock (GVL)—when discussing threading and concurrency as it relates to Ruby, and how it prevents programmers from leveraging those aforementioned techniques. This is far from the truth, so the purpose of this entry is to help clear up some misunderstandings about Ruby and make clear that Ruby is a concurrent friendly language, notwithstanding the GVL.

We'll start by discussing the GVL—what it is and what it isn't—then demonstrate some Ruby concurrency by first building a simple single-threaded TCP echo server, and iterating upon it to make it multithreaded. So without further adieu...

## What is the GVL?
Ruby was developed well before multicore processors and threading became mainstream; but when they became inevitable, Ruby, a language full of mutable references, needed some way to minimize the likelihood of data races or even memory leaks which might be caused by multiple simultaneously running threads accessing shared memory. The simplest approach to reducing the chances of these things happening was to implement some sort of mutex around Ruby's VM, requiring any thread that needs CPU time to acquire the lock before its Ruby code could be interpreted. This is the Global VM Lock.

**In summary**: If your Ruby program has multiple threads, only one thread can be scheduled on a CPU core at any given time. The thread that gets scheduled is the one that manages to acquire the GVL. The trade-off to the memory safety that the GVL affords us is a lack of parallelism (multiple threads running at the same time), but what about concurrency?

## Concurrency in Ruby
Let's start with a simple TCP echo server:
```ruby
  require "socket"
  
  server = TCPServer.new ENV["PORT"] || 8080
  server.listen(20)

  loop do
    conn = server.accept

    sleep 2
    conn.write conn.recv(1024)
    conn.close
  end

```
Notice that when handling the connection (or client socket), we are sleeping for 2 seconds. This is just to simulate some actual work being done and will also make our benchmarks a bit nicer to digest.

For our client, we'll do a quick and dirty bash script which sends 3 requests in parallel to our echo server with "soup" as the outgoing payload:

```bash
# client.sh
for _ in {1..3}; do
  echo "soup" | nc localhost 8080 &
done

for job in `jobs -p`; do
  wait $job
done
```

Now once we run our server, execute our bash script, and time how long it takes to complete, we get predictable results:
```
$ time bash client.sh
soup
soup
soup
0.05s user 0.04s system 1% cpu 6.063 total
```
Nothing surprising: Our server blocks on `accept`, waits for a connection from a client, client connects, we get a socket descriptor for the client, and then we block on servicing the client.

**Note: These examples are run on an 8-core machine. Benchmarks may differ depending on how many cores you have.**

Since we block on every client—and servicing each client takes 2 seconds—it's no surprise that our bash script, which makes three requests, takes a total of 6 seconds, even though each request was made in parallel. **This is because Ruby does blocking-IO**.

Unlike Node, for example, Ruby doesn't have an event loop which automatically dispatches IO tasks to the kernel, allowing the main thread to continue without being blocked. This is **non-blocking IO**. 

When a Ruby thread makes, say a network call, the kernel will deschedule the thread, wait until resources become available, then re-schedule it for CPU time once the requested resources do become available.

How is it possible then for Ruby to leverage concurrency when it blocks on IO? Simple: **When a Ruby thread does IO, they let go of the GVL and go to sleep; then another thread can acquire the GVL and get scheduled for CPU time**.

Let's demonstrate by multithreading our echo server:
```ruby
  server = TCPServer.new ENV["PORT"] || 8080
  server.listen(20)

  loop do
    conn = server.accept

    Thread.new do
      sleep 2
      conn.write conn.recv(1024)
      conn.close
    end
  end
```
Now when we fire three parallel requests, these are our benchmarks:
```
$ time bash client.sh
soup
soup
soup
bash client.sh  0.04s user 0.03s system 3% cpu 2.052 total
```
There we have it, we have just achieved concurrency with Ruby. To summarize what we have done:
1. Our server blocks on `accept`.
2. Client makes a connection.
3. We spin up a new operating system thread and offload the handling of the connection to said thread.
4. The main thread returns to the loop, waiting for a new client connection without being blocked.
5. When a thread is ready to write to the client, it acquires the GVL, writes, and terminates.

So, even though a GVL prevents multiple threads from getting CPU time in parallel, **it does not prevent us from having multiple threads wait in parallel**, allowing our program to continue doing other work while some threads are waiting on IO. What happens if I want to send 20 parallel requests?
```bash
for _ in {1..20}; do
  echo "soup" | nc localhost 8080 &
done
...
# bash client.sh  0.12s user 0.16s system 12% cpu 2.117 total
```
Now that's performance.

Now some of you might be choking at this point. Operating system threads are heavy-weight, and spinning them up and down for every single request comes with a lot of overhead. Basically, our thread-per-connection model won't scale well as our system might croak if we start dealing with requests in the tens-of-thousands range. How do we get around this? Some languages utilize event loops, others utilize green threads, two things which I won't discuss in this entry; our approach will be to utilize a threadpool and the concept of workers.

## Implementing a Threadpool
Threadpools are a set of threads initialized at the beginning of a program, which we can reuse in order to negate the overhead of constantly creating and destroying thread, or running into the potential problem of spinning up more threads than our machine can handle. The game plan will be to implement a threadpool which owns a set of workers; each worker will be responsible for managing a single thread, and work will be dispatched to each worker by the threadpool.

We'll start by creating a class called `ThreadPool` which gets initialized with a `size` attribute telling us how many threads we want in our threadpool:
```ruby
"require socket"

class ThreadPool
  DEFAULT_SIZE = 4

  def initialize(size)
    # TODO
  end

  def handle_client(&handler)
    # TODO
  end
end
```
Great, now we want some workers to actually handle client connections. To me, a worker make sense as a subclass of `ThreadPool`, and we want to know a few things about the worker:
- When is it working?
- When is it ready to do some work?

With this in mind, let's add some new code to our `ThreadPool` class:
```ruby
require "ostruct"
require "socket"

class ThreadPool
  DEFAULT_SIZE = 4

  def initialize(size)
    # TODO
  end

  def handle_client(&handler)
    # TODO
  end
 
  class Worker
    # Basically an enumeration, allowing us to refer to valid states with STATES.ready and STATES.working
    STATES = OpenStruct.new(
      ready: "ready",
      working: "working",
    ).freeze

    # Defines ready? and working? as instance methods on Worker.
    # worker.ready? will return true if worker.state == "ready"
    STATES.to_h.each do |_, v|
      define_method("#{v}?") { state == v }
    end

    attr_reader :id, :state

    def initialize(id:)
      @id = id # A unique id for each worker
      @state = STATES.ready # Each worker is initialized, ready to do work
      @job = nil # The job that the worker will execute.
      @thread = Thread.new do
        loop do
          Thread.stop # To avoid a busy loop, we'll sleep the thread until there is work available
          @job.call # Execute the job when woken up and work is available.
        rescue IOError => e # Some basic error handling
          puts e.message
        ensure # Ensure our work resets back to a usuable state in case of a panic.
          @state = STATES.ready
          @job = nil
        end
      end # Return to the loop, sleep until woken up.
    end

    def run(job)
      # This method is what will be called on the worker when work is available.
      @state = STATES.working # Set the state of the worker to "working".
      @job = job # Assign the worker a job
      @thread.run # Wake up the thread.
    end
  end
end
```
That was a lot, but now we have a `Worker` class that gets initialized with a sleeping thread that is ready to do work whenever available. The `ThreadPool`, which basically acts as our executor, will be responsible for delegating work to an available worker. When the worker is working on the job, it will be in a state of "working", marking it unavailable to receive other work. When the worker is finished with its job, it will return to a "ready" state, and go back to sleep until it is woken back up. So the game plan will be to have the threadpool:
- Initialize with N workers.
- When a client connects, query for a worker that is in a "ready" state, and pass it a closure to handle the client connection with.
- If all workers are in a "working" state, keep polling each worker every 100ms until one becomes available.

Let's take this idea and implement our `initialize` and `handle_client` methods:
```ruby
...
class ThreadPool
  DEFAULT_SIZE = 4

  attr_reader :workers

  class AllWorkersBusy < StandardError; end # The error we wish to raise when all workers are busy

  def initialize(size)
    @workers = (0...size).map { |i| Worker.new id: i }
  end

  def handle_client(&handler)
    loop do
      worker = workers.find { |w| w.ready? } or raise AllWorkersBusy # Query for an available worker
      worker.run handler # Pass the available worker a closure/proc to handle the client connection with.
      break # exit the loop
    rescue AllWorkersBusy # If all workers are busy, sleep for 100ms, and return to the loop to continuously poll for an available worker.
      sleep 0.1
    end

    true
  end
...
```
 Now all there is left to do is implement graceful shutdown, which captures the `SIGINT` (Ctrl-c) signal on Unix-like operating systems, closes the server socket, and allows each worker to finish their current task before shutting them down one-by-one:
 ```ruby
...
class ThreadPool
  ...
  def shutdown
    puts "Waiting for all workers to complete current jobs..."
    until workers.all?(&:ready?)
      sleep 0.1 
    end
    puts "Shutting down workers..."
    @workers.each(&:terminate)
  end

  class Worker
    ...
    def terminate
      @thread.terminate
    end
  end
end
```

Now putting it all together to use practically:
```ruby
if __FILE__ == $0
  puts ENV["PORT"]
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
```
With a default threadpool size of 4, what happens if we were to send 20 parallel requests?
```
$ time bash client.sh
bash client.sh  0.11s user 0.18s system 2% cpu 10.400 total
```
This makes total sense:
- 4 threads in the Threadpool means that we can service 4 requests concurrently at a rate of 4 requests every 2 seconds.
- 20 requests divided by 4 requests per 2 seconds = 10 seconds

We lost a bit of performance compared to the thread-per-connection model, but we can always compensate by icnreasing the size of threadpool. We also have fine grain control over how many workers we want our program to have and will never have to worry about the overhead creating and destroying thread repeatedly, or creating more threads than our machine can handle. Just for good measure, let's increase our threadpool size to 20 and see what happens:
```
bash client.sh  0.11s user 0.15s system 12% cpu 2.121 total
```
Noice.

## Conclusion
Theses should be your main takeaway points:
- Ruby can multithread, but only one thread—the thread with the GVL—can have CPU time at any given time.
- Ruby does blocking-IO, but blocked threads don't block your entire program. Waiting threads can all wait in parallel.
- Ruby is fully capable of concurrency.

Thanks for reading! All of the code is available in this repo.

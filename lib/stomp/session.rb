module Stomp

  # This class provides a way of synchronously receiving messages off the queue.
  # It is (obviously) only safe to access from one thread at a time
  #
  # Every call waits to receive confirmation that the broker received the
  # command before returning.
  class Session
    # these headers are passed to every call made by this session
    attr_reader :default_headers

    # set to sensible (imho) defaults for use with ActiveMQ when consistency
    # is the primary concern
    #
    attr_reader :subscribe_headers

    # a little box we can drop things in for cross-thread communication
    Memo = Struct.new(:receipt)

    def initialize(client, default_headers={})
      @client = client
      @cv = ConditionVariable.new
      @mutex = Mutex.new
      @last_receipt = nil
      @default_headers = default_headers
      @txn_count = 0
      @txn_id = nil
    end

    # blocks until we receive a receipt from the server
    #
    # if a block is given, will be called after the receipt is *synchronously*
    # received (for compatibility)
    #
    # returns receipt string
    #
    def send(destination, message, headers={})
      sync_and_wait_for_signal do |memo|
        client.send(destination, message, headers) do |r|
          sync_then_signal { memo.receipt = r }
        end
      end
    end

    # Begins a transaction that lasts for the duration of the block.
    #
    # If the block exits without throwing an exception, commit the transaction.
    #
    # If an exception is raised, rollback the transaction then re-raise the
    # error.
    #
    # Nested transactions are not supported. If you call this method inside of
    # a transaction, this method is a no-op and the outermost transaction is
    # the winner.
    #
    # returns the value of the block
    #
    def transaction
      return yield if txn_open?
      set_txn_id!

      sync_call_client(:begin, @txn_id)

      rval = yield

      sync_call_client(:commit, @txn_id)

      rval
    rescue Exception => e
      sync_call_client(:rollback, @txn_id)
      raise e
    ensure
      clear_txn_id!
    end

    def acknowledge(message, headers={})
      sync_call_client(:acknowledge, message, headers)
    end


    protected
      def txn_open?
        false|@txn_id
      end

      def set_txn_id!
        @txn_id ||= "transaction-#{@txn_count += 1}-#{self.object_id}"
      end

      def clear_txn_id!
        @txn_id = nil
      end

      def sync_call_client(meth, *args)
        headers = extract_headers(args)
        headers = default_headers.merge(headers)
        headers[:transaction] = @txn_id if txn_open?

        sync_and_wait_for_signal do |memo|
          headers['receipt'] = client.register_receipt_listener { |r| memo.receipt = r; sync_then_signal }
          args << headers

          client.__send__(meth, *args)
        end
      end

      def extract_headers(ary)
        args.last.kind_of?(Hash) ? args.pop : {}
      end

      def reply_callback
        lambda { |r| wake_main_thread! }
      end

      def sync_and_wait_for_signal
        memo = Memo.new
        @mutex.synchronize do
          yield memo if block_given?
          @cv.wait(@mutex)
        end
        memo.receipt
      end

      # tries to synchronize the mutex, when it succeeds
      # calls the block and signals the other thread
      def sync_then_signal
        @mutex.synchronize do
          yield if block_given?
          @cv.signal
        end
      end
  end
end


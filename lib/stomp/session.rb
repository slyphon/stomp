module Stomp
  # This class provides a way of synchronously receiving messages off the queue.
  # It is (obviously) only safe to access from one thread at a time
  #
  # Every call waits to receive confirmation that the broker received the
  # command before returning. (this may become optional in the future)
  class Session
    # these headers are passed to every call made by this session
    attr_reader :default_headers

    # set to sensible (imho) defaults for use with ActiveMQ when consistency
    # is the primary concern
    #
    attr_reader :subscribe_headers

    # a little box we can drop things in for cross-thread communication
    Memo = Struct.new(:receipt)

    def initialize(client, opts={})
      @client = client
      @cv = ConditionVariable.new
      @mutex = Mutex.new
      @last_receipt = nil
      @default_headers = {}
      @subscribe_headers = {}
      @txn_count = 0
      @txn_id = nil

      require 'logger'
      @log = Logger.new('/tmp/session.log')
      @log.level = Logger::DEBUG

      parse_opts(opts)
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
       @client.send(destination, message, headers) do |r|
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
      def parse_opts(opts)
        opts.uncamelize_and_stringfy.each do |k,v|
          case k
          when /^(exclusive|retroactive)$/
            @subscribe_headers[:"activemq.#{k}"] = v
          when /^(dispatch_async|maximum_pending_message_limit|prefetch_size|subscription_name|noLocal)$/
            @subscribe_headers[:"activemq.#{camelize(k,false)}"] = v
          when 'selector'
            @subscribe_headers[k] = v
          else
            @default_headers[k.to_sym] = v
          end
        end
      end
      
      # stolen from activesupport-2.2.2
      def camelize(lower_case_and_underscored_word, first_letter_in_uppercase = true)
        if first_letter_in_uppercase
          lower_case_and_underscored_word.to_s.gsub(/\/(.?)/) { "::#{$1.upcase}" }.gsub(/(?:^|_)(.)/) { $1.upcase }
        else
          lower_case_and_underscored_word.first.downcase + camelize(lower_case_and_underscored_word)[1..-1]
        end
      end

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
        @log.fatal "sync_call_client called with #{meth.inspect} #{args.inspect}"
        headers = extract_headers(args)

        defaults = (meth == :subscribe) ? @subscribe_headers : @default_headers

        headers = defaults.merge(headers)
        headers[:transaction] = @txn_id if @txn_id

        sync_and_wait_for_signal(headers) do |memo,hdrs|
          cb = lambda { |r| memo.receipt = r; sync_then_signal }

          hdrs['receipt'] = client.register_receipt_listener(cb)
          args << hdrs

          @log.fatal "calling client.#{meth} with #{args.inspect}"

          @client.__send__(meth, *args)
        end
      end

      def extract_headers(ary)
        args.last.kind_of?(Hash) ? args.pop : {}
      end

      def sync_and_wait_for_signal(*args)
        memo = Memo.new
        @mutex.synchronize do
          @log.fatal "YIELDING"
          yield(memo,*args) if block_given?
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


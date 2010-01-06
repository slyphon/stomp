module Stomp
  # This class provides a way of synchronously receiving messages off the queue. 
  # It is (obviously) only safe to access from one thread at a time
  #
  # Every call waits to receive confirmation that the broker received the
  # command before returning.
  class SynchronousClient < Client

    def initialize(*a)
      super
      @_cv = ConditionVariable.new
      @_mutex = Mutex.new
    end

    # blocks until we receive a receipt from the server
    #
    # if a block is given, will be called after the receipt is *synchronously*
    # received (for compatibility)
    #
    # returns receipt string
    #
    def send(destination, message, headers={})
      a = []
      @_mutex.synchronize do
        super(destination, message, headers) { |r| a.unshift(r); wake_main_thread! }

        @_cv.wait(@_mutex)
      end

      yield a.first if block_given?

      a.first
    end

    def begin(name, headers={})
      a = []
      cb = lambda { |rcpt| a << rcpt }
      headers['receipt'] = register_receipt_listener(cb)
      super(name, headers)

      Thread.pass while a.empty?
      a.first
    end

    def abort(name, headers={})
      a = []
      cb = lambda { |rcpt| a << rcpt }
      headers['receipt'] = register_receipt_listener(cb)
      super(name, headers)

      Thread.pass while a.empty?
      a.first
    end

    def commit(name, headers={})
      a = []
      cb = lambda { |rcpt| a << rcpt }
      headers['receipt'] = register_receipt_listener(cb)
      super(name, headers)

      Thread.pass while a.empty?
      a.first
    end

    private
      def reply_callback
        lambda { |r| wake_main_thread! }
      end

      def wake_main_thread!
        @_mutex.synchronize { @_cv.signal }
      end
  end
end


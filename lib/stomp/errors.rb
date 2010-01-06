module Stomp
  module Errors
    class StompError < StandardError; end

    class MaxConnectionAttemptsReachedError < StompError; end
  end
end


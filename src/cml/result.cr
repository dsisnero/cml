# src/cml/result.cr
#
# Port of SML/NJ CML util/result.sml to Crystal
# COPYRIGHT (c) 1996 AT&T Research.
#
# A Result is an IVar that can hold either a value or an exception.
# This is useful for RPC-style communication where the server might
# raise an exception that should be propagated to the client.
#
# SML signature:
#   Result : sig
#     type 'a result
#     val result : unit -> 'a result
#     val put    : ('a result * 'a) -> unit
#     val putExn : ('a result * exn) -> unit
#     val get    : 'a result -> 'a
#     val getEvt : 'a result -> 'a event
#   end

require "../cml"
require "../ivar"

module CML
  # Internal wrapper for result values
  private record ResultValue(T), type : Symbol, value : T | Exception

  # A Result wraps an IVar to hold either a value or an exception.
  # When getting the value, if an exception was stored, it is raised.
  class Result(T)
    @ivar : IVar(ResultValue(T))

    # Create a new empty Result
    def initialize
      @ivar = IVar(ResultValue(T)).new
    end

    # Put a successful value into the Result
    # Equivalent to SML's: val put : ('a result * 'a) -> unit
    def put(value : T)
      @ivar.i_put(ResultValue(T).new(:value, value))
    end

    # Put an exception into the Result
    # Equivalent to SML's: val putExn : ('a result * exn) -> unit
    def put_exn(ex : Exception)
      @ivar.i_put(ResultValue(T).new(:exception, ex))
    end

    # Get the value from the Result, raising if an exception was stored
    # Equivalent to SML's: val get : 'a result -> 'a
    def get : T
      CML.sync(evt)
    end

    # Event for getting the value from the Result
    # Equivalent to SML's: val getEvt : 'a result -> 'a event
    def evt : Event(T)
      CML.wrap(@ivar.read_evt) do |result|
        case result.type
        when :value
          result.value.as(T)
        when :exception
          raise result.value.as(Exception)
        else
          raise "Invalid result type"
        end
      end
    end
  end

  # -----------------------
  # Module-level API
  # -----------------------

  # Create a new empty Result
  def self.result(type : T.class) : Result(T) forall T
    Result(T).new
  end

  # Put a value into a Result
  def self.result_put(result : Result(T), value : T) forall T
    result.put(value)
  end

  # Put an exception into a Result
  def self.result_put_exn(result : Result(T), ex : Exception) forall T
    result.put_exn(ex)
  end

  # Get a value from a Result (blocking)
  def self.result_get(result : Result(T)) : T forall T
    result.get
  end

  # Event for getting a value from a Result
  def self.result_get_evt(result : Result(T)) : Event(T) forall T
    result.evt
  end
end

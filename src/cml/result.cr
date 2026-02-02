# Result - Write-once container that can hold a value or exception
#
# Port of SML/NJ CML util/result.sml
#
# SML signature:
#   type 'a result
#   val result : unit -> 'a result
#   val put    : ('a result * 'a) -> unit
#   val putExn : ('a result * exn) -> unit
#   val get    : 'a result -> 'a
#   val getEvt : 'a result -> 'a event

module CML
  class Result(T)
    # Internal value representation to preserve exception semantics.
    private abstract class Value(U)
      abstract def unwrap : U
    end

    private class Res(U) < Value(U)
      def initialize(@value : U)
      end

      def unwrap : U
        @value
      end
    end

    private class Exn(U) < Value(U)
      def initialize(@exn : Exception)
      end

      def unwrap : U
        raise @exn
      end
    end

    @ivar : IVar(Value(T))

    # SML: val result : unit -> 'a result
    def initialize
      @ivar = IVar(Value(T)).new
    end

    # SML: val put : ('a result * 'a) -> unit
    def put(value : T) : Nil
      @ivar.i_put(Res(T).new(value))
    end

    # SML: val putExn : ('a result * exn) -> unit
    def put_exn(ex : Exception) : Nil
      @ivar.i_put(Exn(T).new(ex))
    end

    # SML: val get : 'a result -> 'a
    def get : T
      @ivar.i_get.unwrap
    end

    # SML: val getEvt : 'a result -> 'a event
    def get_evt : Event(T)
      CML.wrap(@ivar.i_get_evt) { |value| value.unwrap }
    end
  end
end

include Binary_codec_intf
include Binary_codec_intf.Types
open Type_core
open Staging
module Sizer = Size.Sizer

let unsafe_add_bytes b k = k (Bytes.unsafe_to_string b)
let str = Bytes.unsafe_of_string

let charstring_of_code : int -> string =
  let tbl =
    Array.init 256 (fun i -> Bytes.unsafe_to_string (Bytes.make 1 (Char.chr i)))
  in
  fun [@inline always] i ->
    assert (i < 256);
    Array.unsafe_get tbl i

module Unit = struct
  let encode () _k = ()
  let decode _ ofs = (ofs, ()) [@@inline always]
  let sizer = Sizer.static 0
end

module Char = struct
  let encode c k = k (charstring_of_code (Char.code c))
  let decode buf ofs = (ofs + 1, buf.[ofs]) [@@inline always]
  let sizer = Sizer.static 1
end

module Bool = struct
  let encode b = Char.encode (if b then '\255' else '\000')

  let decode buf ofs =
    let ofs, c = Char.decode buf ofs in
    match c with '\000' -> (ofs, false) | _ -> (ofs, true)

  let sizer = Sizer.static 1
end

module Int8 = struct
  let encode i k = k (charstring_of_code i)

  let decode buf ofs =
    let ofs, c = Char.decode buf ofs in
    (ofs, Stdlib.Char.code c)
    [@@inline always]
end

module Int16 = struct
  let encode i =
    let b = Bytes.create 2 in
    Bytes.set_uint16_be b 0 i;
    unsafe_add_bytes b

  let decode buf ofs = (ofs + 2, Bytes.get_uint16_be (str buf) ofs)
  let sizer = Sizer.static 2
end

module Int32 = struct
  let encode i =
    let b = Bytes.create 4 in
    Bytes.set_int32_be b 0 i;
    unsafe_add_bytes b

  let decode buf ofs = (ofs + 4, Bytes.get_int32_be (str buf) ofs)
  let sizer = Sizer.static 4
end

module Int64 = struct
  let encode i =
    let b = Bytes.create 8 in
    Bytes.set_int64_be b 0 i;
    unsafe_add_bytes b

  let decode buf ofs = (ofs + 8, Bytes.get_int64_be (str buf) ofs)
  let sizer = Sizer.static 8
end

module Float = struct
  let encode f = Int64.encode (Stdlib.Int64.bits_of_float f)

  let decode buf ofs =
    let ofs, f = Int64.decode buf ofs in
    (ofs, Stdlib.Int64.float_of_bits f)

  (* NOTE: we consider 'double' here *)
  let sizer = Sizer.static 8
end

module Int = struct
  let encode i k =
    let rec aux n k =
      if n >= 0 && n < 128 then k (charstring_of_code n)
      else
        let out = 128 lor (n land 127) in
        k (charstring_of_code out);
        aux (n lsr 7) k
    in
    aux i k

  let decode buf ofs =
    let rec aux buf n p ofs =
      let ofs, i = Int8.decode buf ofs in
      let n = n + ((i land 127) lsl p) in
      if i >= 0 && i < 128 then (ofs, n) else aux buf n (p + 7) ofs
    in
    aux buf 0 0 ofs

  let sizer =
    let of_value =
      let rec aux len n =
        if n >= 0 && n < 128 then len else aux (len + 1) (n lsr 7)
      in
      fun n -> aux 1 n
    in
    let of_encoding buf (Size.Offset off) =
      Size.Offset (fst (decode buf off))
    in
    Sizer.dynamic ~of_value ~of_encoding
end

module Len = struct
  let encode n =
    stage (fun i ->
        match n with
        | `Int -> Int.encode i
        | `Int8 -> Int8.encode i
        | `Int16 -> Int16.encode i
        | `Int32 -> Int32.encode (Stdlib.Int32.of_int i)
        | `Int64 -> Int64.encode (Stdlib.Int64.of_int i)
        | `Fixed _ -> Unit.encode ()
        | `Unboxed -> Unit.encode ())

  let decode n =
    stage (fun buf ofs ->
        match n with
        | `Int -> Int.decode buf ofs
        | `Int8 -> Int8.decode buf ofs
        | `Int16 -> Int16.decode buf ofs
        | `Int32 ->
            let ofs, i = Int32.decode buf ofs in
            (ofs, Stdlib.Int32.to_int i)
        | `Int64 ->
            let ofs, i = Int64.decode buf ofs in
            (ofs, Stdlib.Int64.to_int i)
        | `Fixed n -> (ofs, n)
        | `Unboxed -> (ofs, String.length buf - ofs))

  let sizer = function
    | `Int -> Int.sizer
    | `Int8 -> Sizer.static 1
    | `Int16 -> Sizer.static 2
    | `Int32 -> Sizer.static 4
    | `Int64 -> Sizer.static 8
    | `Fixed _ -> Sizer.static 0
    | `Unboxed -> Sizer.static 0
end

(* Helper functions generalising over [string] / [bytes]. *)
module Mono_container = struct
  let decode_unboxed of_string of_bytes =
    stage @@ fun buf ofs ->
    let len = String.length buf - ofs in
    if ofs = 0 then (len, of_string buf)
    else
      let str = Bytes.create len in
      String.blit buf ofs str 0 len;
      (ofs + len, of_bytes str)

  let decode of_string of_bytes =
    let sub len buf ofs =
      if ofs = 0 && len = String.length buf then (len, of_string buf)
      else
        let str = Bytes.create len in
        String.blit buf ofs str 0 len;
        (ofs + len, of_bytes str)
    in
    function
    | `Fixed n ->
        (* fixed-size strings are never boxed *)
        stage @@ fun buf ofs -> sub n buf ofs
    | n ->
        let decode_len = unstage (Len.decode n) in
        stage @@ fun buf ofs ->
        let ofs, len = decode_len buf ofs in
        sub len buf ofs

  let sizer_unboxed ~length = function
    | `Fixed n -> Sizer.static n (* fixed-size containers are never boxed *)
    | _ -> { of_value = Dynamic length; of_encoding = Unknown }
  (* NOTE: this is the one case where we can't recover the length of an
     encoding from its initial offset, given a structurally-defined codec. *)

  let sizer ~length header_typ =
    let size_of_header = (Len.sizer header_typ).of_value in
    match (size_of_header, header_typ) with
    | Static n, `Fixed str_len -> Sizer.static (n + str_len)
    | _, _ -> (
        let decode_len = unstage (Len.decode header_typ) in
        let of_encoding buf (Size.Offset off) =
          let off, size = decode_len buf off in
          assert (size >= 0);
          Size.Offset (off + size)
        in
        match size_of_header with
        | Unknown -> assert false
        | Static n ->
            Sizer.dynamic ~of_encoding ~of_value:(fun s -> n + length s)
        | Dynamic f ->
            Sizer.dynamic ~of_encoding ~of_value:(fun s ->
                let s_len = length s in
                f s_len + s_len))
end

module String_unboxed = struct
  let encode _ = stage (fun s k -> k s)

  let decode _ =
    Mono_container.decode_unboxed (fun x -> x) Bytes.unsafe_to_string

  let sizer n = Mono_container.sizer_unboxed ~length:String.length n
end

module Bytes_unboxed = struct
  (* NOTE: makes a copy of [b], since [k] may retain the string it's given *)
  let encode _ = stage (fun b k -> k (Bytes.to_string b))

  let decode _ =
    Mono_container.decode_unboxed Bytes.unsafe_of_string (fun x -> x)

  let sizer n = Mono_container.sizer_unboxed ~length:Bytes.length n
end

module String = struct
  let encode len =
    let encode_len = unstage (Len.encode len) in
    stage (fun s k ->
        let i = String.length s in
        encode_len i k;
        k s)

  let decode len = Mono_container.decode (fun x -> x) Bytes.unsafe_to_string len
  let sizer n = Mono_container.sizer ~length:String.length n
end

module Bytes = struct
  let encode len =
    let encode_len = unstage (Len.encode len) in
    stage (fun s k ->
        let i = Bytes.length s in
        encode_len i k;
        unsafe_add_bytes s k)

  let decode len = Mono_container.decode Bytes.unsafe_of_string (fun x -> x) len
  let sizer len = Mono_container.sizer ~length:Bytes.length len
end

module Option = struct
  let encode encode_elt v k =
    match v with
    | None -> Char.encode '\000' k
    | Some x ->
        Char.encode '\255' k;
        encode_elt x k

  let decode decode_elt buf ofs =
    let ofs, c = Char.decode buf ofs in
    match c with
    | '\000' -> (ofs, None)
    | _ ->
        let ofs, x = decode_elt buf ofs in
        (ofs, Some x)

  let sizer : type a. a Sizer.t -> a option Sizer.t =
   fun elt ->
    let header_size = 1 in
    match elt with
    | { of_value = Static 0; _ } ->
        Sizer.static header_size (* Either '\000' or '\255' *)
    | { of_value = Static n; _ } ->
        (* Must add [n] in the [Some _] case, otherwise just header size. *)
        let of_value = function
          | None -> header_size
          | Some _ -> header_size + n
        in
        let of_encoding buf (Size.Offset off) =
          match Stdlib.String.get buf off with
          | '\000' -> Size.Offset (off + 1)
          | _ -> Size.Offset (1 + n)
        in
        Sizer.dynamic ~of_value ~of_encoding
    | elt ->
        (* Must dynamically compute element size in the [Some _] case. *)
        let open Size.Syntax in
        let of_value =
          let+ elt_encode = elt.of_value in
          function None -> header_size | Some x -> header_size + elt_encode x
        in
        let of_encoding =
          let+ elt_decode = elt.of_encoding in
          fun buf (Size.Offset off) ->
            match Stdlib.String.get buf off with
            | '\000' -> Size.Offset (off + 1)
            | _ -> elt_decode buf (Size.Offset (off + 1))
        in
        { of_value; of_encoding }
end

(* Helper functions generalising over [list] / [array]. *)
module Poly_container = struct
  let sizer :
      type a at.
      length:(at -> int) ->
      fold_left:(f:(int -> a -> int) -> init:int -> at -> int) ->
      len ->
      a sizer ->
      at sizer =
   fun ~length ~fold_left header_typ elt_size ->
    let header_size = (Len.sizer header_typ).of_value in
    match (header_typ, header_size, elt_size) with
    | _, Size.Unknown, _ -> assert false
    | `Fixed length, Static header_size, { of_value = Static elt_size; _ } ->
        (* We don't serialise headers for fixed-size containers *)
        assert (header_size = 0);
        Sizer.static (length * elt_size)
    | _, _, { of_value = Static elt_size; _ } ->
        let of_value =
          (* Number of elements not fixed, so we must check it dynamically *)
          match header_size with
          | Unknown -> assert false
          | Static header_size ->
              fun l ->
                let nb_elements = length l in
                header_size + (elt_size * nb_elements)
          | Dynamic header_size ->
              fun l ->
                let nb_elements = length l in
                header_size nb_elements + (elt_size * nb_elements)
        in
        let of_encoding =
          (* Read the header to recover the length. Don't need to look at
             elements as they have static size. *)
          let decode_len = unstage (Len.decode header_typ) in
          fun buf (Size.Offset off) ->
            let off, elements = decode_len buf off in
            Size.Offset (off + (elt_size * elements))
        in
        Sizer.dynamic ~of_value ~of_encoding
    | _ ->
        let open Size.Syntax in
        let of_value =
          (* Must traverse the container _and_ compute element sizes
             individually *)
          let+ elt_size = elt_size.of_value in
          match header_size with
          | Unknown -> assert false
          | Static header_size ->
              fun l ->
                fold_left l ~init:header_size ~f:(fun acc x -> acc + elt_size x)
          | Dynamic header_size ->
              fun l ->
                let len = length l in
                let header_size = header_size len in
                fold_left l ~init:header_size ~f:(fun acc x -> acc + elt_size x)
        in
        let of_encoding =
          let+ elt_decode = elt_size.of_encoding in
          let rec decode_elements buf off todo =
            match todo with
            | 0 -> off
            | n -> decode_elements buf (elt_decode buf off) (n - 1)
          in
          let decode_len = unstage (Len.decode header_typ) in
          fun buf (Size.Offset off) ->
            let off, elements = decode_len buf off in
            decode_elements buf (Size.Offset off) elements
        in
        { of_value; of_encoding }
end

module List = struct
  let encode =
    let rec encode_elements encode_elt k = function
      | [] -> ()
      | x :: xs ->
          encode_elt x k;
          (encode_elements [@tailcall]) encode_elt k xs
    in
    fun len encode_elt ->
      let encode_len = unstage (Len.encode len) in
      stage (fun x k ->
          encode_len (List.length x) k;
          encode_elements encode_elt k x)

  let decode =
    let rec decode_elements decode_elt acc buf off = function
      | 0 -> (off, List.rev acc)
      | n ->
          let off, x = decode_elt buf off in
          decode_elements decode_elt (x :: acc) buf off (n - 1)
    in
    fun len decode_elt ->
      let decode_len = unstage (Len.decode len) in
      stage (fun buf ofs ->
          let ofs, len = decode_len buf ofs in
          decode_elements decode_elt [] buf ofs len)

  let sizer len elt =
    Poly_container.sizer ~length:List.length ~fold_left:ListLabels.fold_left len
      elt
end

module Array = struct
  let encode =
    let encode_elements encode_elt k arr =
      for i = 0 to Array.length arr - 1 do
        encode_elt (Array.unsafe_get arr i) k
      done
    in
    fun n l ->
      let encode_len = unstage (Len.encode n) in
      stage (fun x k ->
          encode_len (Array.length x) k;
          encode_elements l k x)

  let decode len decode_elt =
    let list_decode = unstage (List.decode len decode_elt) in
    stage (fun buf off ->
        let ofs, l = list_decode buf off in
        (ofs, Array.of_list l))

  let sizer len elt =
    Poly_container.sizer ~length:Array.length ~fold_left:ArrayLabels.fold_left
      len elt
end

module Pair = struct
  let encode a b (x, y) k =
    a x k;
    b y k

  let decode a b buf off =
    let off, a = a buf off in
    let off, b = b buf off in
    (off, (a, b))

  let sizer a b = Sizer.(using fst a <+> using snd b)
end

module Triple = struct
  let encode a b c (x, y, z) k =
    a x k;
    b y k;
    c z k

  let decode a b c buf off =
    let off, a = a buf off in
    let off, b = b buf off in
    let off, c = c buf off in
    (off, (a, b, c))

  let sizer a b c =
    Sizer.(
      using (fun (x, _, _) -> x) a
      <+> using (fun (_, x, _) -> x) b
      <+> using (fun (_, _, x) -> x) c)
end

(*
 * Copyright (c) Citrix Systems Inc.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)
open Sexplib.Std
open Lwt
open Logging
open Clock

module Int64Map = Map.Make(Int64)

type t = {
  q: Protocol.Entry.t Int64Map.t;
  name: string;
  length: int;
  next_id: int64;
  c: unit Lwt_condition.t;
  m: Lwt_mutex.t
}

let make name = {
  q = Int64Map.empty;
  name = name;
  length = 0;
  next_id = 0L;
  c = Lwt_condition.create ();
  m = Lwt_mutex.create ();
}

module StringMap = Map.Make(String)

type queues = t StringMap.t

let queues = ref StringMap.empty

let startswith prefix x = String.length x >= (String.length prefix) && (String.sub x 0 (String.length prefix) = prefix)

module Lengths = struct
  open Measurable
  let d x =Description.({ description = "length of queue " ^ x; units = "" })
  let list_available () =
    StringMap.fold (fun name _ acc ->
        (name, d name) :: acc
      ) !queues []
  let measure name =
    if StringMap.mem name !queues
    then Some (Measurement.Int (StringMap.find name !queues).length)
    else None
end

(* operations which need to be persisted *)
module Op = struct
  type directory_operation =
    | Add of string
    | Remove of string
  with sexp

  type t =
    | Directory of directory_operation
    | Ack of Protocol.message_id
    | Send of Protocol.origin * string * int64 * Protocol.Message.t (* origin * queue * id * body *)
  with sexp

  let of_cstruct x =
    try
      Some (Cstruct.to_string x |> Sexplib.Sexp.of_string |> t_of_sexp)
    with _ ->
      None

  let to_cstruct t =
    let s = sexp_of_t t |> Sexplib.Sexp.to_string in
    let c = Cstruct.create (String.length s) in
    Cstruct.blit_from_string s 0 c 0 (Cstruct.len c);
    c
end

module Redo_log = Shared_block.Journal.Make(Logging)(Block)(Time)(Clock)(Op)

module Internal = struct
module Directory = struct
  let waiters = Hashtbl.create 128

  let wait_for name =
    let t, u = Lwt.task () in
    let existing = if Hashtbl.mem waiters name then Hashtbl.find waiters name else [] in
    Hashtbl.replace waiters name (u :: existing);
    Lwt.on_cancel t
      (fun () ->
         if Hashtbl.mem waiters name then begin
           let existing = Hashtbl.find waiters name in
           Hashtbl.replace waiters name (List.filter (fun x -> x <> u) existing)
         end
      );
    t

  let exists name = StringMap.mem name !queues

  let add name =
    if not(exists name) then begin
      queues := StringMap.add name (make name) !queues;
      if Hashtbl.mem waiters name then begin
        let threads = Hashtbl.find waiters name in
        Hashtbl.remove waiters name;
        List.iter (fun u -> Lwt.wakeup_later u ()) threads
      end
    end

  let find name =
    if exists name
    then StringMap.find name !queues
    else make name

  let remove name =
    queues := StringMap.remove name !queues

  let list prefix = StringMap.fold (fun name _ acc ->
      if startswith prefix name
      then name :: acc
      else acc) !queues []
end

let transfer from names =
  let messages = List.map (fun name ->
      let q = Directory.find name in
      let _, _, not_seen = Int64Map.split from q.q in
      Int64Map.fold (fun id e acc ->
          ((name, id), e.Protocol.Entry.message) :: acc
        ) not_seen []
    ) names in
  List.concat messages

let queue_of_id = fst

let entry (name, id) =
  let q = Directory.find name in
  if Int64Map.mem id q.q
  then Some (Int64Map.find id q.q)
  else None

let ack (name, id) =
  if Directory.exists name then begin
    let q = Directory.find name in
    if Int64Map.mem id q.q then begin
      let q' = { q with
                 length = q.length - 1;
                 q = Int64Map.remove id q.q
               } in
      queues := StringMap.add name q' !queues
    end
  end

let wait from name =
  if Directory.exists name then begin
    (* Wait for some messages to turn up *)
    let q = Directory.find name in
    Lwt_mutex.with_lock q.m
      (fun () ->
         let rec loop () =
           let _, _, not_seen = Int64Map.split from ((Directory.find name).q) in
           if not_seen = Int64Map.empty then begin
             lwt () = Lwt_condition.wait ~mutex:q.m q.c in
             loop ()
           end else return () in
         loop ()
      )
  end else begin
    (* Wait for the queue to be created *)
    Directory.wait_for name;
  end

let send origin name id data : unit Lwt.t =
  (* If a queue doesn't exist then drop the message *)
  if Directory.exists name then begin
    let q = Directory.find name in
    Lwt_mutex.with_lock q.m
      (fun () ->
         let q' = { q with
                    length = q.length + 1;
                    q = Int64Map.add id (Protocol.Entry.make (ns ()) origin data) q.q
                  } in
         queues := StringMap.add name q' !queues;
         Lwt_condition.broadcast q.c ();
         return ()
      )
  end else return ()

let contents q = Int64Map.fold (fun i e acc -> ((q.name, i), e) :: acc) q.q []

let get_next_id name =
  if Directory.exists name then begin
    let q = Directory.find name in
    Lwt_mutex.with_lock q.m
      (fun () ->
        let id = q.next_id in
        let q' = { q with next_id = Int64.succ q.next_id } in
        queues := StringMap.add name q' !queues;
        return (Some id)
      )
  end else return None
end

let perform_one = function
  | Op.Directory (Op.Add name) -> Internal.Directory.add name; return ()
  | Op.Directory (Op.Remove name) -> Internal.Directory.remove name; return ()
  | Op.Ack id -> Internal.ack id; return ()
  | Op.Send (origin, name, id, body) -> Internal.send origin name id body

let contents = Internal.contents

module Directory = struct
  let add = Internal.Directory.add
  let remove = Internal.Directory.remove
  let find = Internal.Directory.find
  let list = Internal.Directory.list
end

let queue_of_id = Internal.queue_of_id
let ack = Internal.ack
let transfer = Internal.transfer
let wait = Internal.wait
let entry = Internal.entry
let send origin name body =
  Internal.get_next_id name
  >>= function
  | None -> return None
  | Some id ->
    Internal.send origin name id body
    >>= fun () ->
    return (Some (name, id))

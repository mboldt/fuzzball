(*
  Based on stp_external_engine.ml, which bears the following notice:
  Copyright (C) BitBlaze, 2009-2011, and copyright (C) 2010 Ensighta
  Security Inc.  All rights reserved.
*)

(* This file shares a lot of code with both stp_external_engine (which
   is also batch but STP CVC format) and smtlib_external_engine (which is
   also SMTLIB2 but push/pop incremental). Perhaps some kind of
   refactoring would be worthwhile. *)

module V = Vine;;

open Exec_exceptions;;
open Exec_options;;
open Query_engine;;
open Smt_lib2;;

let map_lines f chan =
  let results = ref [] in
    (try while true do
       match (f (input_line chan)) with
	 | Some x -> results := x :: !results
	 | None -> ()
     done
     with End_of_file -> ());
    List.rev !results

let rename_var name =
  let new_name = ref "" in
    for i = 0 to (String.length name) - 1 do
      match name.[i] with
        | '_' -> new_name := !new_name ^ "-"
        | '-' -> new_name := !new_name ^ "_"
       | '|' -> ()
        | _ -> new_name := !new_name ^ (Char.escaped name.[i])
    done;
    !new_name

let parse_counterex line =
  if line = "sat" then
    None
  else
    (assert((String.sub line 0 8) = "ASSERT( ");
     assert((String.sub line ((String.length line) - 3) 3) = " );");
     let trimmed = String.sub line 8 ((String.length line) - 11) in
     let eq_loc = String.index trimmed '=' in
     let lhs = String.sub trimmed 0 eq_loc and
	 rhs = (String.sub trimmed (eq_loc + 1)
		  ((String.length trimmed) - eq_loc - 1)) in
       assert((String.sub lhs ((String.length lhs) - 1) 1) = " "
	   || (String.sub lhs ((String.length lhs) - 1) 1) = "<");
       let lhs_rtrim =
	 if (String.sub lhs ((String.length lhs) - 2) 1) = " " then
	   2 else 1
       in
       let rhs_rtrim =
	 if (String.sub rhs ((String.length rhs) - 1) 1) = " " then
	   1 else 0
       in
       let varname_raw = String.sub lhs 0 ((String.length lhs) - lhs_rtrim) in
       let varname = rename_var varname_raw in
       let value =
	 let rhs' = String.sub rhs 0 ((String.length rhs) - rhs_rtrim) in
	 let len = String.length rhs' in
	   (Int64.of_string
	      (if len >= 6 && (String.sub rhs' 0 5) = " 0hex" then
		 ("0x" ^ (String.sub rhs' 5 (len - 5)))
	       else if len >= 4 && (String.sub rhs' 0 3) = " 0x" then
		 ("0x" ^ (String.sub rhs' 3 (len - 3)))
	       else if len >= 4 && (String.sub rhs' 0 3) = " 0b" then
		 ("0b" ^ (String.sub rhs' 3 (len - 3)))
	       else if rhs' = ">FALSE" then
		 "0"
	       else if rhs' = ">TRUE" then
		 "1"
	       else
		 failwith "Failed to parse value in counterexample"))
       in
	 Some (varname, value))


class smtlib_batch_engine fname = object(self)
  inherit query_engine

  val mutable chan = None
  val mutable visitor = None
  val mutable temp_dir = None
  val mutable filenum = 0
  val mutable curr_fname = fname

  method private get_temp_dir =
    match temp_dir with
      | Some t -> t
      | None ->
	  let rec loop num =
	    let name = Printf.sprintf "fuzzball-tmp-%d" num in
	      if Sys.file_exists name then
		loop (num + 1)
	      else
		(Unix.mkdir name 0o777;
		 temp_dir <- Some name;
		 name)
	  in
	    loop 1

  method private get_fresh_fname =
    let split_limbs n m =
      let rec loop n =
	if n < m then
	  [n]
	else
	  (n mod m) :: loop (n / m)
      in
	loop n
    in
    let make_dirs parent limbs =
      let rec loop p l =
	match l with
	  | [] -> p
	  | n :: rest ->
	      let dir = p ^ "/" ^ Printf.sprintf "%03d" n in
		if not (Sys.file_exists dir) then
		  Unix.mkdir dir 0o777;
		loop dir rest
      in
	loop parent limbs
    in
    let dir = self#get_temp_dir in
      filenum <- filenum + 1;
      let (low, rest) = match split_limbs filenum 1000 with
	| (low :: rest) -> (low, rest)
	| _ -> failwith "Non-empty list invariant failure in get_fresh_fname"
      in
      let dir' = make_dirs dir (List.rev rest) in
        ignore(low);
	curr_fname <- (Printf.sprintf "%s/%s-%d" dir' fname filenum);
	if !opt_trace_solver then
	  Printf.printf "Creating SMTLIB2 file: %s.smt2\n" curr_fname;
	curr_fname

  method private chan =
    match chan with
      | Some c -> c
      | None -> failwith "Missing output channel in smtlib_batch_engine"

  method private visitor =
    match visitor with
      | Some v -> v
      | None -> failwith "Missing visitor in smtlib_batch_engine"

  val mutable free_vars = []
  val mutable eqns = []
  val mutable conds = []

  method start_query =
    ()

  method add_free_var var =
    free_vars <- var :: free_vars

  method private real_add_free_var var =
    self#visitor#declare_var var

  method add_temp_var var =
    ()

  method assert_eq var rhs =
    eqns <- (var, rhs) :: eqns;

  method add_condition e =
    conds <- e :: conds

  val mutable ctx_stack = []

  method push =
    ctx_stack <- (free_vars, eqns, conds) :: ctx_stack

  method pop =
    match ctx_stack with
      | (free_vars', eqns', conds') :: rest ->
	  free_vars <- free_vars';
	  eqns <- eqns';
	  conds <- conds';
	  ctx_stack <- rest
      | [] -> failwith "Context underflow in smtlib_batch_engine#pop"

  method private real_assert_eq (var, rhs) =
    try
      self#visitor#declare_var_value var rhs
    with
      | V.TypeError(err) ->
	  Printf.printf "Typecheck failure on %s: %s\n"
	    (V.exp_to_string rhs) err;
	  failwith "Typecheck failure in assert_eq"

  method private real_prepare =
    let fname = self#get_fresh_fname in
      chan <- Some(open_out (fname ^ ".smt2"));
      visitor <- Some(new Smt_lib2.vine_smtlib_print_visitor
			(output_string self#chan));
      output_string self#chan
	"(set-logic QF_BV)\n(set-info :smt-lib-version 2.0)\n\n";
      List.iter self#real_add_free_var (List.rev free_vars);
      List.iter self#real_assert_eq (List.rev eqns);

  method query qe =
    self#real_prepare;
    output_string self#chan "\n";
    let conj = List.fold_left
      (fun es e -> V.BinOp(V.BITAND, e, es)) qe (List.rev conds)
    in
      (let visitor = (self#visitor :> V.vine_visitor) in
       let rec loop = function
	 | V.BinOp(V.BITAND, e1, e2) ->
	     loop e1;
	     (* output_string self#chan "\n"; *)
	     loop e2
	 | e ->
	     output_string self#chan "(assert ";
	     ignore(V.exp_accept visitor e);
	     output_string self#chan ")\n"
       in
	 loop conj);
    output_string self#chan "\n(check-sat)\n";
    output_string self#chan "(exit)\n";
    close_out self#chan;
    chan <- None;
    let timeout_opt = match !opt_solver_timeout with
      | Some s -> "-g " ^ (string_of_int s) ^ " "
      | None -> ""
    in
    let cmd = !opt_solver_path ^ " --SMTLIB2 -p " ^ timeout_opt ^ curr_fname
      ^ ".smt2 >" ^ curr_fname ^ ".smt2.out" in
      if !opt_trace_solver then
	Printf.printf "Solver command: %s\n" cmd;
      flush stdout;
      let rcode = Sys.command cmd in
      let results = open_in (curr_fname ^ ".smt2.out") in
	if rcode <> 0 then
	  (Printf.printf "Solver died with result code %d\n" rcode;
	   (match rcode with
	      | 127 ->
		  if !opt_solver_path = "stp" then
		    Printf.printf
		      "Perhaps you should set the -solver-path option?\n"
		  else if String.contains !opt_solver_path '/' &&
		    not (Sys.file_exists !opt_solver_path)
		  then
		    Printf.printf "The file %s does not appear to exist\n"
		      !opt_solver_path
	      | 131 -> raise (Signal "QUIT")
	      | _ -> ());
	   ignore(Sys.command ("cat " ^ curr_fname ^ ".smt2.out"));
	   (None, []))
	else
	  let result_s = input_line results in
	  let first_assert = (String.sub result_s 0 3) = "ASS" in
	  let result = match result_s with
	    | "unsat" -> Some true
	    | "Timed Out." -> Printf.printf "Solver timeout\n"; None
	    | "sat" -> Some false
	    | _ when first_assert -> Some false
	    | _ -> failwith "Unexpected first output line"
	  in
	  let first_assign = if first_assert then
	    [(match parse_counterex result_s with
		| Some ce -> ce | None -> failwith "Unexpected parse failure")]
	  else
	    [] in
	  let ce = map_lines parse_counterex results in
	    close_in results;
	    (result, first_assign @ ce)

  method after_query save_results =
    if save_results then
      Printf.printf "Solver query and results are in %s.smt2 and %s.smt2.out\n"
	curr_fname curr_fname
    else if not !opt_save_solver_files then
      (Sys.remove (curr_fname ^ ".smt2");
       Sys.remove (curr_fname ^ ".smt2.out"))

  method reset =
    visitor <- None;
    free_vars <- [];
    eqns <- [];
    conds <- []
end

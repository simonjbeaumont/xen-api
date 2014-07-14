(*
 * Copyright (C) 2006-2014 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

module M = struct
	type ('a, 'b) t = [ `Ok of 'a | `Error of 'b ]
    let (>>=) m f = match m with | `Ok x -> f x | `Error x -> `Error x
    let return x = `Ok x
end

open M

module Xenops_record = struct
	type t = {
		time: string;
		word_size: int;
	} with rpc

	let make () =
		let word_size = Sys.word_size
		and time = Date.(to_string (of_float (Unix.time ()))) in
		{ word_size; time }
	
	let to_string t = Jsonrpc.to_string (rpc_of_t t)
	let of_string s = t_of_rpc (Jsonrpc.of_string s)
end


type format = Structured | Legacy

type header_type =
	| Xenops
	| Libxc
	| Libxl
	| Libxc_legacy
	| Qemu_trad
	| Qemu_xen
	| Demu
	| End_of_image

exception Invalid_header_type

let header_type_of_int64 = function
	| 0x000fL -> `Ok Xenops
	| 0x00f0L -> `Ok Libxc
	| 0x00f1L -> `Ok Libxl
	| 0x00f2L -> `Ok Libxc_legacy
	| 0x0f00L -> `Ok Qemu_trad
	| 0x0f01L -> `Ok Qemu_xen
	| 0x0f10L -> `Ok Demu
	| 0xffffL -> `Ok End_of_image
	| _ -> `Error Invalid_header_type

let int64_of_header_type = function
	| Xenops       -> 0x000fL
	| Libxc        -> 0x00f0L
	| Libxl        -> 0x00f1L
	| Libxc_legacy -> 0x00f2L
	| Qemu_trad    -> 0x0f00L
	| Qemu_xen     -> 0x0f01L
	| Demu         -> 0x0f10L
	| End_of_image -> 0xffffL

type header = header_type * int64 (* length *)

let wrap f =
	try
		return (f ())
	with e -> 
		`Error e

let read_int64 fd = wrap (fun () -> Io.read_int64 ~endianness:`little fd)
let write_int64 fd x = wrap (fun () -> Io.write_int64 ~endianness:`little fd x)

let save_signature = "XenSavedDomv2-\n"
let legacy_save_signature = "XenSavedDomain\n"
let legacy_qemu_save_signature = "QemuDeviceModelRecord\n"
let qemu_save_signature_upstream_libxc = "DeviceModelRecord0002\n"

let write_save_signature fd = Io.write fd save_signature
let read_save_signature fd =
	match Io.read fd (String.length save_signature) with
	| x when x = save_signature -> `Ok Structured
	| x when x = legacy_save_signature -> `Ok Legacy
	| x -> `Error (Printf.sprintf "Not a valid signature: \"%s\"" x)

let read_legacy_qemu_header fd =
	try
		match Io.read fd (String.length legacy_qemu_save_signature) with
		| x when x = legacy_qemu_save_signature ->
			`Ok (Int64.of_int (Io.read_int ~endianness:`big fd))
		| x -> `Error "Read invalid legacy qemu save signature"
	with e ->
		`Error ("Failed to read signature: " ^ (Printexc.to_string e))

let write_qemu_header_for_upstream_libxc fd size =
	wrap (fun () -> Io.write fd qemu_save_signature_upstream_libxc) >>= fun () ->
	wrap (fun () -> Io.write_int ~endianness:`little fd (Io.int_of_int64_exn size))

let read_header fd =
	read_int64 fd >>= fun x ->
	header_type_of_int64 x >>= fun hdr ->
	read_int64 fd >>= fun len ->
	return (hdr, len)

let write_header fd (hdr_type, len) =
	write_int64 fd (int64_of_header_type hdr_type) >>= fun () ->
	write_int64 fd len

type 'a thread_status = Running | Thread_failure of exn | Success of 'a

let with_conversion_script task name hvm fd f =
	let module D = Debug.Debugger(struct let name = "suspend_image_conversion" end) in
	let open D in
	let open Pervasiveext in
	let open Threadext in
	let (pipe_r, pipe_w) = Unix.pipe () in
	let fd_uuid = Uuid.(to_string (make_uuid ()))
	and pipe_w_uuid = Uuid.to_string (Uuid.make_uuid ()) in
	let conv_script = "/usr/lib64/xen/bin/legacy.py"
	and args =
		[ "--in"; fd_uuid; "--out"; pipe_w_uuid;
			"--width"; "32"; "--skip-qemu";
			"--guest-type"; if hvm then "hvm" else "pv";
			"--syslog";
		]
	in
	let (m, c) = Mutex.create (), Condition.create () in
	let spawn_thread_and_close_fd name fd' f =
		let status = ref Running in
		let thread =
			Thread.create (fun () ->
				try
					let result =
						finally (fun () -> f ()) (fun () -> Unix.close fd')
					in
					Mutex.execute m (fun () ->
						status := Success result;
						Condition.signal c
					)
				with e ->
					Mutex.execute m (fun () ->
						status := Thread_failure e;
						Condition.signal c
					)
			) ()
		in
		(thread, status)
	in
	let (conv_th, conv_st) =
		spawn_thread_and_close_fd "legacy.py" pipe_w (fun () ->
			Cancel_utils.cancellable_subprocess task
				[ fd_uuid, fd; pipe_w_uuid, pipe_w; ] conv_script args
		)
	and (f_th, f_st) =
		spawn_thread_and_close_fd name pipe_r (fun () ->
			f pipe_r
		)
	in
	debug "Spawned threads for conversion script and %s" name;
	let rec handle_threads () = match (!conv_st, !f_st) with
	| Thread_failure e, _ ->
		`Error (Failure (Printf.sprintf "Conversion script thread caught exception: %s"
			(Printexc.to_string e)))
	| _, Thread_failure e ->
		`Error (Failure (Printf.sprintf "Thread executing %s caught exception: %s"
			name (Printexc.to_string e)))
	| Running, _ | _, Running ->
		Condition.wait c m;
		handle_threads ()
	| Success _, Success res ->
		debug "Waiting for conversion script thread to join";
		Thread.join conv_th;
		debug "Waiting for xenguest thread to join";
		Thread.join f_th;
		`Ok res
	in
	Mutex.execute m handle_threads

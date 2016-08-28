open Core_kernel.Std

type t =
  { session : Wrapper.Session.t
  ; graph : Wrapper.Graph.t
  ; nodes : Wrapper.Graph.operation Node.Id.Table.t
  }

let create () =
  let graph = Wrapper.Graph.create () in
  match Wrapper.Session.create graph with
  | Error status ->
    failwithf "Unable to generate session: %s" (Wrapper.Status.message status) ()
  | Ok session ->
    { session
    ; graph
    ; nodes = Node.Id.Table.create ()
    }

let default_session = lazy (create ())

let add_attribute operation_description ~attr_name attr =
  match (attr : Node.attr) with
  | String str ->
    Wrapper.Graph.set_attr_string operation_description ~attr_name str
  | Type dtype ->
    let dtype = Node.Type.to_data_type dtype in
    Wrapper.Graph.set_attr_type operation_description ~attr_name dtype
  | Tensor_float tensor_float ->
    let set_attr kind =
      let tensor = Tensor.create kind (Array.of_list tensor_float.shape) in
      Tensor.copy_elt_list tensor tensor_float.values;
      Wrapper.Graph.set_attr_tensor operation_description ~attr_name (Tensor.P tensor)
      |> Wrapper.Status.ok_exn
    in
    begin
      match tensor_float.type_ with
      | Node.Type.P Node.Type.Float -> set_attr Float32
      | Node.Type.P Node.Type.Double -> set_attr Float64
      | Node.Type.P _ -> assert false
    end
  | Tensor_int tensor_int ->
    let tensor =
      match tensor_int.type_ with
      | Node.Type.P Node.Type.Int32 ->
        let tensor = Tensor.create Int32 (Array.of_list tensor_int.shape) in
        Tensor.copy_elt_list tensor (List.map tensor_int.values ~f:Int32.of_int_exn);
        Tensor.P tensor
      | Node.Type.P Node.Type.Int64 ->
        let tensor = Tensor.create Int64 (Array.of_list tensor_int.shape) in
        Tensor.copy_elt_list tensor (List.map tensor_int.values ~f:Int64.of_int_exn);
        Tensor.P tensor
      | Node.Type.P _ -> assert false
    in
    Wrapper.Graph.set_attr_tensor operation_description ~attr_name tensor
    |> Wrapper.Status.ok_exn
  | Int i ->
    Wrapper.Graph.set_attr_int operation_description ~attr_name i
  | Float f ->
    Wrapper.Graph.set_attr_float operation_description ~attr_name f
  | Bool b ->
    Wrapper.Graph.set_attr_bool operation_description ~attr_name b
  | Shape shape ->
    let shape = List.map shape ~f:(fun dim -> dim.size) in
    Wrapper.Graph.set_attr_shape operation_description ~attr_name shape
  | List _ -> failwith "List attributes are not supported yet."
  | Tensor_string _ -> failwith "Tensor_string attributes are not supported yet."

let rec build t node ~variable_initializations =
  let id = Node.packed_id node in
  match Hashtbl.find t.nodes id with
  | Some op -> op
  | None ->
    let Node.P u_node = node in
    let operation_description =
      Wrapper.Graph.new_operation t.graph
        ~op_name:(Node.op_name u_node |> Node.Op_name.to_string)
        ~name:(Node.unique_name u_node)
    in
    List.iter (Node.inputs u_node) ~f:(function
      | `single input ->
        Wrapper.Graph.add_input
          operation_description
          (build t input ~variable_initializations)
          ~index:(Node.packed_output_idx input |> Option.value ~default:0)
      | `multi inputs ->
        let inputs =
          List.map inputs ~f:(fun input ->
            let index = Node.packed_output_idx input |> Option.value ~default:0 in
            build t input ~variable_initializations, index)
        in
        Wrapper.Graph.add_inputs operation_description inputs);
    List.iter (Node.attributes u_node) ~f:(fun (attr_name, attr) ->
      add_attribute operation_description ~attr_name attr);
    let operation =
      Wrapper.Graph.finish_operation operation_description
      |> Wrapper.Status.ok_exn
    in
    Hashtbl.set t.nodes ~key:id ~data:operation;
    Option.iter (Var.get_init u_node) ~f:(fun init_node ->
      let assign_node = Ops_generated.assign u_node init_node in
      let assign_op = build t (P assign_node) ~variable_initializations in
      variable_initializations := assign_op :: !variable_initializations);
    operation

let run ?(inputs=[]) ?(outputs=[]) ?(targets=[]) t =
  let variable_initializations = ref [] in
  if List.contains_dup (List.map inputs ~f:fst)
  then failwith "Session.run: duplicate entry in [inputs].";
  let inputs =
    List.map inputs ~f:(fun (input, input_tensor) ->
      let op = build t input ~variable_initializations in
      Wrapper.Graph.create_port op ~index:0, input_tensor)
  in
  let outputs = List.map outputs ~f:(build t ~variable_initializations) in
  let targets =
    List.map targets ~f:(build t ~variable_initializations) @ outputs
  in
  let outputs = List.map outputs ~f:(fun op -> Wrapper.Graph.create_port op ~index:0) in
  (* [variable_initializations] is topologically sorted. *)
  List.iter (List.rev !variable_initializations) ~f:(fun init_op ->
    Wrapper.Session.run t.session ~inputs ~outputs:[] ~targets:[ init_op ]
    |> Wrapper.Status.ok_exn
    |> fun l -> assert (List.is_empty l));
  Wrapper.Session.run t.session ~inputs ~outputs ~targets
  |> Wrapper.Status.ok_exn

module Input = struct
   type t =
   | I : _ Ops.Placeholder.t * (_,_) Tensor.t -> t

  let float
        (node : [ `float ] Ops.Placeholder.t)
        (tensor : (float, Bigarray.float32_elt) Tensor.t)
    =
    I (node, tensor)

  let double
        (node : [ `double ] Ops.Placeholder.t)
        (tensor : (float, Bigarray.float64_elt) Tensor.t)
    =
    I (node, tensor)
 end

module Output = struct
  type _ t =
    | Return : 'a -> 'a t
    | Compute : _ Node.t -> Tensor.p t
    | Both : 'a t * 'b t ->  ('a * 'b) t
    | Map : 'a t * ('a -> 'b) -> 'b t
    | Empty : unit t

  let map t ~f = Map (t, f)
  let return node = Return node
  let both t1 t2 = Both (t1, t2)
  let empty = Empty

  let three t1 t2 t3 =
    both t1 (both t2 t3) |> map ~f:(fun (t1, (t2, t3)) -> t1, t2, t3)

  let four t1 t2 t3 t4 =
    both (both t1 t2) (both t3 t4)
    |> map ~f:(fun ((t1, t2), (t3, t4)) -> t1, t2, t3, t4)

  let five t1 t2 t3 t4 t5 =
    both (both (both t1 t2) (both t3 t4)) t5
    |> map ~f:(fun (((t1, t2), (t3, t4)), t5) -> t1, t2, t3, t4, t5)

  let six t1 t2 t3 t4 t5 t6 =
    both (both (both t1 t2) (both t3 t4)) (both t5 t6)
    |> map ~f:(fun (((t1, t2), (t3, t4)), (t5, t6)) -> t1, t2, t3, t4, t5, t6)

  (* CR-someday noury: this could be just one function with modular implicits *)
  let float (node : [`float] Node.t) : (float, Bigarray.float32_elt) Tensor.t t =
    Compute node
    |> map ~f:(fun (Tensor.P tensor) ->
      match Tensor.kind tensor with
      | Bigarray.Float32 -> (tensor : (float, Bigarray.float32_elt) Tensor.t)
      | _ -> failwith "PANIC: wrong kind in float")

  let double (node : [`double] Node.t) : (float, Bigarray.float64_elt) Tensor.t t =
    Compute node
    |> map ~f:(fun (Tensor.P tensor) ->
      match Tensor.kind tensor with
      | Bigarray.Float64 -> (tensor : (float, Bigarray.float64_elt) Tensor.t)
      | _ -> failwith "PANIC: wrong kind in double")

  let int32 (node : [`int32] Node.t) : (int32, Bigarray.int32_elt) Tensor.t t =
    Compute node
    |> map ~f:(fun (Tensor.P tensor) ->
      match Tensor.kind tensor with
      | Bigarray.Int32 -> (tensor : (int32, Bigarray.int32_elt) Tensor.t)
      | _ -> failwith "PANIC: wrong kind in double")

  let int64 (node : [`int64] Node.t) : (Int64.t, Bigarray.int64_elt) Tensor.t t =
    Compute node
    |> map ~f:(fun (Tensor.P tensor) ->
      match Tensor.kind tensor with
      | Bigarray.Int64 -> (tensor : (Int64.t, Bigarray.int64_elt) Tensor.t)
      | _ -> failwith "PANIC: wrong kind in double")

  (* CR noury: add more output types *)

  let scalar_gen extract node =
    extract node |> map ~f:(fun t ->
      Array.create 0 ~len:(Tensor.num_dims t)
      |> Tensor.get t)

  let scalar_float n = scalar_gen float n
  let scalar_double n = scalar_gen double n
  let scalar_int32 n = scalar_gen int32 n |> map ~f:Int32.to_int_exn
  let scalar_int64 n = scalar_gen int64 n

  let rec build_output
    : type a. a t ->  (Node.p list -> Node.p list) * (Tensor.p list -> a * Tensor.p list) =
    function
    | Return a -> (fun l -> l), (fun l -> a, l)
    | Both (o1, o2) ->
      let l1, k1 = build_output o1 in
      let l2, k2 = build_output o2 in
      (fun l -> l1 (l2 l)),
      (fun l ->
        let a, l = k1 l in
        let b, l = k2 l in
        (a, b), l)
    | Map (o, f) ->
      let l, k = build_output o in
      l, (fun l -> let a, l = k l in f a, l)
    | Empty -> Fn.id, fun l -> (), l
    | Compute node ->
     (fun l -> (P node) :: l),
     function
     | t::l -> t, l
     | [] -> failwith "wrong number of elts in output dispatch"

  let build_output o =
   let f, k = build_output o in
   f [], fun l -> fst (k l)
end

let run ?inputs ?targets ?session output =
  let t =
    match session with
    | None -> Lazy.force default_session
    | Some session -> session
  in
  let inputs =
    Option.map inputs ~f:(List.map ~f:(fun (Input.I (n, t)) ->
      Node.P (Ops.Placeholder.to_node n), Tensor.P t))
  in
  let outputs, k = Output.build_output output in
  k (run ?inputs ?targets ~outputs t)

import onnx, sys
m = onnx.load(sys.argv[1], load_external_data=False)
for n in m.graph.node:
    if '/m_source/' in n.name or n.name in ('Reshape_6496','Shape_6488') or n.name.startswith('/encoder/Reshape') or n.name=='/encoder/MatMul_1':
        print(n.op_type, n.name, list(n.input), list(n.output))

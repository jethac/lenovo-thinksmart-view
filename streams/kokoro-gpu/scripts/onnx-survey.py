import onnx, sys, collections
m = onnx.load(sys.argv[1], load_external_data=False)
g = m.graph
print([ (i.name) for i in g.input], [o.name for o in g.output])
c = collections.Counter(n.op_type for n in g.node)
print(c.most_common())
for n in g.node:
    if 'Random' in n.op_type or n.op_type in ('STFT','DFT'):
        print(n.op_type, n.name, list(n.input), list(n.output), [(a.name, onnx.helper.get_attribute_value(a)) for a in n.attribute])
# find decoder boundary: first nodes with /decoder/ in name, and their inputs from non-decoder
prod = {o: n for n in g.node for o in n.output}
ins = set()
for n in g.node:
    if n.name.startswith('/decoder/'):
        for i in n.input:
            p = prod.get(i)
            if p is not None and not p.name.startswith('/decoder/'):
                ins.add((i, p.op_type, p.name))
for x in sorted(ins): print('BOUNDARY', x)

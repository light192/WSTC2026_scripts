import os, zipfile, re, xml.etree.ElementTree as ET
from pathlib import Path

files = [r'd:\Worldskills\WSTC2026\B1\new\B1_Competitor_Task_RU_published_topology_v2.docx', r'd:\Worldskills\WSTC2026\B1\new\B1_marking_scheme_CIS_published_topology_25_revised.xlsx']

for f in files:
    print('===', os.path.basename(f), '===')
    if f.endswith('.docx'):
        with zipfile.ZipFile(f) as z:
            for name in z.namelist():
                if name.endswith('document.xml'):
                    data = z.read(name)
                    root = ET.fromstring(data)
                    ns={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
                    paras=[]
                    for p in root.findall('.//w:p', ns):
                        parts=[]
                        for t in p.findall('.//w:t', ns):
                            parts.append(t.text or '')
                        txt=''.join(parts)
                        if txt.strip():
                            paras.append(txt)
                    # print first 800 lines
                    for line in paras[:1200]:
                        print(line)
                    break
    elif f.endswith('.xlsx'):
        with zipfile.ZipFile(f) as z:
            # print shared strings and sheet names
            names=[]
            wb = ET.fromstring(z.read('xl/workbook.xml'))
            ns={'main':'http://schemas.openxmlformats.org/spreadsheetml/2006/main','r':'http://schemas.openxmlformats.org/officeDocument/2006/relationships'}
            for sheet in wb.find('main:sheets', ns):
                names.append(sheet.attrib.get('{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id'))
            print('sheet rel ids:', names)
            shared=[]
            if 'xl/sharedStrings.xml' in z.namelist():
                ss=ET.fromstring(z.read('xl/sharedStrings.xml'))
                for si in ss.findall('main:si', ns):
                    txt=''.join(t.text or '' for t in si.findall('.//main:t', ns))
                    shared.append(txt)
                print('shared strings count', len(shared))
                for s in shared[:300]:
                    print(s)
            # dump sheet XML names
            for name in z.namelist():
                if name.startswith('xl/worksheets/sheet') and name.endswith('.xml'):
                    print('sheet file', name)
                    data=ET.fromstring(z.read(name))
                    rows=[]
                    for row in data.findall('.//main:row', ns):
                        vals=[]
                        for c in row.findall('main:c', ns):
                            t=c.attrib.get('t')
                            v=c.find('main:v',ns)
                            if v is None:
                                vals.append('')
                            else:
                                val=v.text or ''
                                if t=='s':
                                    try: val=shared[int(val)]
                                    except: pass
                                vals.append(val)
                        if any(v!='' for v in vals):
                            rows.append(vals)
                    for row in rows[:40]:
                        print(row)
                    break
    print()
PY
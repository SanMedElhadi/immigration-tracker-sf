#!/usr/bin/env python3
"""Remove <fieldPermissions> blocks from every permission set in a folder.

Salesforce rejects a permission set that references a field which does not exist
in the target org ("no CustomField named X found"). Rather than hand-editing four
large XML files, run this with the field API names from the deploy errors.

    python3 scripts/strip-field-permission.py \
        force-app/main/default/permissionsets \
        Application_Type__c.Fee_Currency__c Document__c.Some_Field__c

Re-add the field permissions later by regenerating, or by creating the field and
running a retrieve.
"""
import os, re, sys, glob

if len(sys.argv) < 3:
    sys.exit(__doc__)

folder, fields = sys.argv[1], sys.argv[2:]
total = 0
for path in sorted(glob.glob(os.path.join(folder, "*.permissionset-meta.xml"))):
    text = original = open(path, encoding="utf-8").read()
    for field in fields:
        text, n = re.subn(
            r"    <fieldPermissions>\n(?:(?!</fieldPermissions>).)*?<field>"
            + re.escape(field) + r"</field>.*?</fieldPermissions>\n",
            "", text, flags=re.S)
        if n:
            print("  removed %-45s from %s" % (field, os.path.basename(path)))
            total += n
    if text != original:
        open(path, "w", encoding="utf-8").write(text)
print("removed %d field permission block(s)" % total)

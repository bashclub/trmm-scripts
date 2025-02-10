#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# vim: set fileencoding=utf-8:noet

##  Copyright 2023 Bashclub https://github.com/bashclub
##  BSD-2-Clause
##
##  Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
##
##  1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
##
##  2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
##
## THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
## THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS
## BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
## GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
## LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

__VERSION__ = "0.1.1"

import requests
import os
import json
import re
import smtplib
import socket
import ssl
from datetime import datetime
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formataddr

from pprint import pprint

NAMES = {
    "customer"      : u"Kunde",
    "workstation"   : u"Workstation",
    "server"        : u"Server",
    "other"         : u"Sonstiges"
}

TEXT_NOCHANGES = u"Keine Änderungen"
TEXT_CHANGES = u"{count} Änderung(en) seit dem {lastmodified}"
SUBJECTNAME = u"TacticalRMM - Kundenübersicht - {changes}"

HTML_TEMPLATE = u"""
<html>
<head>
<style type="text/css">
    table {{border-collapse:collapse; border-spacing:0; font-family:Arial, sans-serif; font-size:14px; overflow:hidden; padding: 5px; work-breaking:normal;border-color:black; border-style:solid; vertical-align: middle}}
    td {{border-width: 1px;text-align: left;}}
    th {{padding:5px;}}
    td.unchanged {{background-color: #a9ffa1;}}
    td.changed {{background-color: #ffa1a1;}}
    p.changed {{color:#8a0000; font-weight: bold;}}
    p.unchanged {{color:#1c8a00;}}
</style>
</head>
<body>
<p>
{HTMLSUMMARY}
Heutiger Kundenstand:
<table>
<tr><th>Kunde</th><th>Workstations</th><th>Server</th><th>Sonstiges</th></tr>
{HTMLTABLE}
</table>
<br><br>
Dies ist eine automatisch generierte E-Mail
</p>
</body>
</html>
"""

SCRIPTPATH = os.path.realpath(os.path.abspath(__file__))
SCRIPTDIR = os.path.dirname(SCRIPTPATH)
CONFIGPATH = os.path.join(SCRIPTDIR,"trmmtracker.conf")

class trmmm_customer(dict):
    def __init__(self,workstation=0,server=0,other=0):
        dict.__init__(self,workstation=workstation,server=server,other=other)

    def add_agent(self,monitoring_type):
        if not monitoring_type:
            return 
        if monitoring_type == "workstation":
            self["workstation"] += 1
        elif monitoring_type == "server":
            self["server"] += 1
        else:
            self["other"] += 1

    def diff(self,other):
        if not other:
            return self.items()
        _ret = {}
        for _k,_v in self.items():
            _diff = _v - other[_k]
            if _diff != 0:
                _ret[_k] = _diff
        return _ret

    def __ne__(self,other):
        if not other:
            return True
        return (
            (self["workstation"] != other["workstation"]) or
            (self["server"] != other["server"]) or
            (self["other"] != other["other"])
        )

class trmm_tracker(object):
    def __init__(self,url,apikey,smtp_server=None,smtp_port=25,mail_from=None,mail_to="",debug=False,**kwargs):
        self.debug = debug
        self.api_url = url
        self.apikey = apikey
        self.smtp_server_addr = smtp_server
        self.smtp_server_port = smtp_port
        self.mail_from_addr = mail_from if mail_from else f"root@{socket.getfqdn()}"
        self.mail_recipients = list(map(str.strip,mail_to.split(",")))
        self._dbpath = os.path.join(SCRIPTDIR,"customer_db.json")
        self._storage = {}
        self._storage_time = datetime.now().strftime('%d.%m.%Y %H:%M')
        self._changes = {}
        self.load_storage()
        if self.check_changes(self.get_agents()):
            self.save_storage()
        self.report()

    def load_storage(self):
        try:
            with open(self._dbpath,"rb") as _f:
                _json = json.load(_f)
            self._storage_time = datetime.fromtimestamp(os.stat(self._dbpath).st_mtime).strftime('%d.%m.%Y %H:%M')
            if type(_json) == dict:
                for _customer,_obj in _json.items():
                    self._storage[_customer] = trmmm_customer(**_obj)
        except (IOError,json.decoder.JSONDecodeError):
            pass

    def save_storage(self):
        with open(self._dbpath,"w") as _f:
            json.dump(self._storage,_f)

    def get_agents(self):
        _req = requests.get(
            f"{self.api_url}/agents/",
            headers={
                "Content-Type"  : "application/json",
                "X-API-KEY"     : self.apikey
            }
        )
        assert _req.status_code == 200
        _json_data = _req.json()
        _tmp_storage = {}
        for _agent in _json_data:
            _customer = _agent.get("client_name")
            if _customer not in _tmp_storage:
                _tmp_storage[_customer] = trmmm_customer()
            _tmp_storage[_customer].add_agent(_agent.get("monitoring_type"))
        return _tmp_storage

    def check_changes(self,_storage):
        for _customer in set(list(_storage.keys()) + list(self._storage.keys())):
            _obj = _storage.get(_customer,trmmm_customer())
            _stored_obj = self._storage.get(_customer)
            if _obj != _stored_obj:
                self._storage[_customer] = _obj
                self._changes[_customer] = _obj.diff(_stored_obj)
        self._num_changes = sum(map(lambda x: len(x.values()) if type(x) == dict else 0,self._changes.values()))
        return self._changes

    def _create_tablerow(self,customer,obj,diffobj={}):
        _html = f"<tr><td>{customer}</td>"
        for _entry in ("workstation","server","other"):
            _val = obj[_entry]
            if _entry in diffobj:
                _diff = diffobj[_entry]
                _diff = str(_diff) if _diff < 0 else f"+{_diff}"
                _html += f'<td class="changed">{_val} ({_diff})</td>'
            else:
                _html += f'<td class="unchanged">{_val}</td>'
        return _html + "</tr>"

    def _create_textrow(self,customer,obj,diffobj={}):
        _text = f"{customer:60.60} "
        for _entry in ("workstation","server","other"):
            _name = NAMES.get(_entry)
            _val = obj[_entry]
            if _entry in diffobj:
                _diff = diffobj[_entry]
                _diff = str(_diff) if _diff < 0 else f"+{_diff}"
                _text += f'- {_name}: {_val!s:4.4} ({_diff!s:3.3})'
            else:
                _text += f'- {_name}: {_val!s:10.10}'
        return _text

    def report(self):
        _changes = dict(self._changes)
        HTMLTABLE = []
        TEXTROWS = []
        for _customer,_obj in sorted(self._storage.items()):
            HTMLTABLE.append(self._create_tablerow(_customer,_obj,_changes.get(_customer,{})))
            TEXTROWS.append(self._create_textrow(_customer,_obj,_changes.get(_customer,{})))
        if self._changes:
            TEXTSUMMARY= TEXT_CHANGES.format(count=self._num_changes, lastmodified=self._storage_time)
            HTMLSUMMARY = f'<p class="changed">{TEXTSUMMARY}</p>'
        else:
            TEXTSUMMARY = TEXT_NOCHANGES.format(count=0, lastmodified=self._storage_time)
            HTMLSUMMARY = f'<p class="unchanged">{TEXTSUMMARY}</p>'
        _text = "\n".join(TEXTROWS) + "\n\n" + TEXTSUMMARY + "\n"
        _html = HTML_TEMPLATE.format(HTMLTABLE="".join(HTMLTABLE),HTMLSUMMARY=HTMLSUMMARY)
        _email = self.create_email_msg(text=_text,html=_html)
        if self.debug:
            print(_text)
        elif self.smtp_server_addr and self.mail_recipients:
            self.send_mail(_email)

    def send_mail(self,msg):
        msg["From"] = formataddr(("TacticalRMM",self.mail_from_addr))
        msg["To"] = ", ".join(self.mail_recipients)
        _conn = smtplib.SMTP(self.smtp_server_addr,self.smtp_server_port)
        _conn.ehlo()
        _context = ssl._create_unverified_context()
        _conn.starttls(context=_context)
        _conn.sendmail(self.mail_from_addr, self.mail_recipients, msg.as_string())
        _conn.quit()

    def create_email_msg(self,text,html):
        _msg = MIMEMultipart("alternative")
        if self._changes:
            _msg["Subject"] = SUBJECTNAME.format(changes=TEXT_CHANGES.format(
                count=self._num_changes, lastmodified=self._storage_time)
            )
        else:
            _msg["Subject"] = SUBJECTNAME.format(changes=TEXT_NOCHANGES.format(
                count=0, lastmodified=self._storage_time)
            )
        _msg.attach(MIMEText(text,"plain","utf-8"))
        _msg.attach(MIMEText(html,"html","utf-8"))
        return _msg

if __name__ == "__main__":
    import argparse 
    _ = lambda x: x
    _parser = argparse.ArgumentParser()
    _parser.add_argument("--debug",action="store_true",
        help=_("debug output / no mail sent"))
    _parser.add_argument("--apikey",type=str,
        help=_("TacticalRMM API Key"))
    _parser.add_argument("--url",type=str,
        help=_("TacticalRMM URL"))
    _parser.add_argument("--smtp-server",type=str,
        help=_("SMTP Server name"))
    _parser.add_argument("--smtp-port",type=int,default=25,
        help=_("SMTP Server Port"))
    _parser.add_argument("--mail-from",type=str,
        help=_("Mail Sender"))
    _parser.add_argument("--mail-to",type=str,default="",
        help=_("Mail Recipient"))
    _parser.add_argument("--config",type=str,dest="configfile",default=CONFIGPATH,
        help=_(f"path to config file ({CONFIGPATH}"))

    args = _parser.parse_args()

    if args.configfile and os.path.exists(args.configfile):
        for _key,_val in re.findall(f"^([\w-]+):\s*(.*?)(?:\s+#|$)",open(args.configfile,"rt").read(),re.M):
            if _key not in ("apikey","url","smtp-server","smtp-port","mail-from","mail-to"):
                continue
            _skey = _key.replace("-","_")
            if _key in ("smtp-port"):
                setattr(args,_skey,int(_val))
            else:
                setattr(args,_skey,_val)
    if not args.url or not args.url.startswith("http"):
        raise Exception(f"Invalid TacticalRMM URL: {args.url}")
    if not args.apikey or len(args.apikey) < 5:
        raise Exception(f"Invalid API Key: {args.apikey}")
    if args.debug:
        pprint(args.__dict__)
    trmm_tracker(**args.__dict__)

"""Discover QQ friends and groups without opening their conversations."""
import argparse
import json
import sys
import unicodedata
from difflib import SequenceMatcher
from urllib import error

from query import Client


def normalize(value):
    value = unicodedata.normalize("NFKC", str(value or ""))
    return "".join(value.casefold().split())


def score(term, fields):
    best = 0
    for field in fields:
        value = normalize(field)
        if not value:
            continue
        if term == value:
            return 4
        if value.startswith(term):
            best = max(best, 3)
        elif term in value:
            best = max(best, 2)
        elif len(term) >= 3 and not term.isdecimal():
            similarity = SequenceMatcher(None, term, value, autojunk=False).ratio()
            if similarity >= 0.65:
                best = max(best, similarity)
    return best


def sessions(client, keyword, kind, top):
    term = normalize(keyword)
    activity = {}
    if not term:
        contacts = client.call("recent-contacts?limit=500&includeAll=true")["contacts"]
        for contact in contacts:
            key = (str(contact.get("chatType")), str(contact.get("peerUid")))
            activity[key] = max(activity.get(key, 0), int(contact.get("lastMsgTime") or 0))

    matches = []
    for category in ("friend", "group"):
        if kind not in ("any", category):
            continue
        friend = category == "friend"
        for row in client.directory("friends" if friend else "groups"):
            number = str(row["uin" if friend else "groupCode"])
            name = row["nick" if friend else "groupName"]
            remark = row.get("remark") or ""
            if term:
                rank = score(term, (name, remark, number))
            else:
                chat_type = "1" if friend else "2"
                rank = max(activity.get((chat_type, number), 0),
                           activity.get((chat_type, str(row.get("uid"))), 0))
            if rank:
                matches.append((rank, {"type": category, "number": number,
                                       "name": name, "remark": remark}))
    matches.sort(key=lambda pair: (-pair[0], pair[1]["name"], pair[1]["number"]))
    return {"count": min(top, len(matches)), "matched": len(matches),
            "sessions": [item for _, item in matches[:top]]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--search", metavar="KEYWORD")
    mode.add_argument("--list", action="store_true")
    parser.add_argument("--type", choices=("any", "friend", "group"), default="any")
    parser.add_argument("--top", type=int, default=10)
    parser.add_argument("--user-consent", required=True, choices=("list", "search"))
    args = parser.parse_args()
    if args.top < 1 or (args.search is not None and not normalize(args.search)):
        parser.error("请输入有效的关键词和正整数条数。")
    if args.user_consent != ("list" if args.list else "search"):
        parser.error("会话发现操作与同意范围不符。")
    try:
        print(json.dumps(sessions(Client(), args.search, args.type, args.top),
                         ensure_ascii=False, indent=2))
    except error.HTTPError as exc:
        sys.exit(f"QCE HTTP {exc.code}，请检查服务和本机授权。")
    except (OSError, KeyError, ValueError) as exc:
        sys.exit(f"QQ 会话发现失败：{exc}")


if __name__ == "__main__":
    main()

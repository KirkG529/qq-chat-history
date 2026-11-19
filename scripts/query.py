"""Read one explicitly authorized QQ conversation through local QCE."""
import argparse
import json
import sys
import time
from datetime import datetime
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib import error, request
from urllib.parse import quote


class LocalOnly(request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


class Client:
    def __init__(self):
        security = Path.home() / ".qq-chat-exporter" / "security.json"
        self.token = json.loads(security.read_text(encoding="utf-8-sig"))["accessToken"]
        self.http = request.build_opener(request.ProxyHandler({}), LocalOnly())

    def call(self, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = request.Request("http://127.0.0.1:40653/api/" + path, data=data,
                              headers={"Authorization": "Bearer " + self.token,
                                       "Content-Type": "application/json"})
        with self.http.open(req, timeout=45) as response:
            payload = json.load(response)
        if not payload.get("success"):
            raise ValueError("QCE 查询失败，请检查登录状态及会话。")
        return payload["data"]

    def directory(self, kind):
        page = 1
        while True:
            data = self.call(f"{kind}?page={page}&limit=100")
            if data["currentPage"] != page:
                raise ValueError("QCE 分页响应与请求不一致。")
            yield from data[kind]
            if not data["hasNext"]:
                break
            page += 1


def resolve(client, query, mode):
    exact, partial = [], []
    for kind in ("friends", "groups"):
        friend = kind == "friends"
        number = "qq" if friend else "group-id"
        fields = {"nick": "nick", "remark": "remark"} if friend else {"group-name": "groupName"}
        if mode == number or (mode == "auto" and query.isdecimal()):
            keys = ["uin" if friend else "groupCode"]
            numeric = True
        else:
            keys = [key for option, key in fields.items() if mode in ("auto", option)]
            numeric = False
        if not keys:
            continue
        for row in client.directory(kind):
            values = [str(row.get(k) or "").strip().casefold() for k in keys]
            term = query.casefold()
            matched = term in values
            if not matched and (numeric or not any(term in v for v in values)):
                continue
            item = {"type": "friend" if friend else "group",
                    "name": row["nick" if friend else "groupName"],
                    "number": str(row["uin" if friend else "groupCode"]),
                    "remark": row.get("remark") or ""}
            peer = {"chatType": 1 if friend else 2,
                    "peerUid": str(row["uid"] if friend else row["groupCode"])}
            (exact if matched else partial).append((item, peer))
    if len(exact) == 1:
        return exact[0]
    candidates = [item for item, _ in (exact or partial)]
    return {"status": "choose" if candidates else "not_found", "candidates": candidates}, None


def content(element):
    labels = {"pic": "图片", "ptt": "语音", "video": "视频", "face": "表情",
              "file": "文件", "reply": "回复", "ark": "卡片", "marketFace": "表情"}
    text = element.get("textElement") or {}
    if text.get("content"):
        return text["content"]
    for key, label in labels.items():
        if element.get(key + "Element") is not None:
            return "[" + label + "]"
    return "[消息类型 " + str(element.get("elementType", "未知")) + "]"


def recent(client, query, mode, limit):
    chat, peer = resolve(client, query, mode)
    if peer is None:
        return chat
    data = client.call("messages/fetch", {"peer": peer, "page": 1, "limit": limit})
    messages = []
    for msg in sorted(data["messages"], key=lambda m: (int(m["msgTime"]), int(m["msgSeq"])),
                      reverse=True)[:limit]:
        if str(msg["peerUid"]) != peer["peerUid"] or int(msg["chatType"]) != peer["chatType"]:
            raise ValueError("返回消息的会话标识不一致。")
        messages.append({"id": str(msg["msgId"]),
                         "time": datetime.fromtimestamp(int(msg["msgTime"])).astimezone().isoformat(),
                         "sender": msg.get("sendMemberName") or msg.get("sendNickName") or str(msg.get("senderUin") or ""),
                         "text": "".join(map(content, msg.get("elements") or [])) or "[无文本]"})
    return {"status": "ok", "chat": chat, "count": len(messages), "messages": messages}


def recover_history(client, peer, directory, minimum):
    """Fetch a fixed time range; verify QCE's count before publishing raw records."""
    end = int(time.time()) * 1000 + 999
    expected = None
    page = 1
    seen = set()
    scratch = NamedTemporaryFile(mode="w", encoding="utf-8", dir=directory,
                                 suffix=".partial", delete=False)
    target = directory / "recovered-messages.jsonl"
    try:
        with scratch:
            while True:
                data = client.call("messages/fetch", {
                    "peer": peer, "page": page, "limit": 100,
                    "filter": {"startTime": 0, "endTime": end}})
                if expected is None:
                    expected = int(data["totalCount"])
                    if expected < minimum:
                        raise ValueError(f"分页接口仅报告 {expected} 条，低于原任务计数 {minimum}。")
                before = len(seen)
                rows = data["messages"]
                for row in rows:
                    if (str(row["peerUid"]) != peer["peerUid"] or
                            int(row["chatType"]) != peer["chatType"]):
                        raise ValueError("分页返回了其他会话的消息。")
                    key = row["msgId"]
                    if key is None or not str(key).strip():
                        raise ValueError("消息缺少可用于去重的 ID。")
                    if str(key) not in seen:
                        seen.add(str(key))
                        scratch.write(json.dumps(row, ensure_ascii=False) + "\n")
                if len(seen) == expected:
                    break
                if not rows or len(seen) == before or len(seen) > expected:
                    raise ValueError(f"分页覆盖未验证：{len(seen)}/{expected} 条唯一消息。")
                # Keep the oldest second inclusive so simultaneous messages survive.
                boundary = min(int(row["msgTime"]) for row in rows) * 1000 + 999
                if boundary < end:
                    end = boundary
                    # If the entire page shares one second, the next page must
                    # continue inside that second, rather than repeat page one.
                    page = 2 if all(int(r["msgTime"]) == boundary // 1000 for r in rows) else 1
                else:
                    page += 1
        Path(scratch.name).rename(target)
    finally:
        Path(scratch.name).unlink(missing_ok=True)
    return {"count": expected, "files": [str(target)], "method": "verified_raw_jsonl"}


def export_all(client, query, mode, directory):
    chat, peer = resolve(client, query, mode)
    if peer is None:
        return chat
    directory = directory.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    task = client.call("messages/export-streaming-jsonl", {
        "peer": {**peer, "guildId": ""}, "sessionName": chat["name"],
        "format": "STREAMING_JSONL", "filter": {"includeRecalled": True},
        "options": {"outputDir": str(directory), "batchSize": 3000,
                    "includeSystemMessages": True, "filterPureImageMessages": False,
                    "includeResourceLinks": False, "exportAsZip": False},
    })
    task_id = str(task["taskId"])
    print(f"QCE 已创建任务 {task_id}；中断后可在 QCE 任务页查看。", file=sys.stderr, flush=True)
    while True:
        state = client.call("tasks/" + quote(task_id, safe=""))
        status = state["status"]
        if status == "completed":
            break
        detail = " ".join(str(state.get(k) or "") for k in
                          ("error", "message", "progressMessage")).lower()
        if status == "failed" and "2004000" in detail and "no any more msg" in detail:
            recovery = recover_history(client, peer, directory, int(state.get("messageCount") or 0))
            return {"status": "ok", "chat": chat, "taskId": task_id,
                    "nativeStatus": "failed", **recovery}
        if status not in ("pending", "queued", "running", "processing"):
            raise ValueError(f"任务 {task_id} 状态为 {status}，未确认完成。")
        time.sleep(2)
    files = [str(p) for p in directory.rglob("*") if p.is_file() and p.suffix.lower() in (".jsonl", ".zip")]
    if not files:
        raise ValueError(f"任务 {task_id} 已结束，但指定目录里未找到导出文件。请查 QCE 任务详情。")
    return {"status": "ok", "chat": chat, "taskId": task_id,
            "count": state.get("messageCount"), "files": files}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("query")
    parser.add_argument("--by", choices=("auto", "nick", "remark", "group-name", "qq", "group-id"), default="auto")
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--limit", type=int, metavar="1-50")
    scope.add_argument("--all", action="store_true", help="导出单个会话全部可读历史")
    parser.add_argument("--user-consent", required=True, choices=("recent", "all"),
                        help="调用者已取得用户对本次目标和范围的明文同意")
    parser.add_argument("--out-dir", type=Path, help="全量导出的新目录")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    term = args.query.strip()
    limit = 5 if args.limit is None else args.limit
    if not term or not 1 <= limit <= 50:
        parser.error("请输入查询目标和 1–50 的条数。")
    if args.user_consent != ("all" if args.all else "recent"):
        parser.error("同意范围与请求不符。")
    if args.all != bool(args.out_dir) or (args.all and args.out):
        parser.error("全量导出需指定 --out-dir 新目录；--out 仅用于最近消息。")
    try:
        client = Client()
        result = (export_all(client, term, args.by, args.out_dir) if args.all
                  else recent(client, term, args.by, limit))
        output = json.dumps(result, ensure_ascii=False, indent=2)
        if args.out and result["status"] == "ok":
            with args.out.open("x", encoding="utf-8") as stream:
                stream.write(output + "\n")
            print(json.dumps({"file": str(args.out.resolve()), "count": result["count"]}, ensure_ascii=False))
        else:
            print(output)
    except error.HTTPError as exc:
        sys.exit(f"QCE HTTP {exc.code}，请检查服务和本机授权。")
    except (OSError, ValueError, KeyError) as exc:
        sys.exit(f"QQ 查询失败：{exc}")


if __name__ == "__main__":
    main()

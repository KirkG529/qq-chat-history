import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import query
import sessions


class QueryTests(unittest.TestCase):
    def setUp(self):
        self.client = Mock()
        self.friend = {"uin": "123", "uid": "u1", "nick": "Alice", "remark": "室友"}
        self.group = {"groupCode": "321", "groupName": "读书会"}
        self.client.directory.side_effect = lambda kind: (
            [self.friend] if kind == "friends" else [self.group])

    def test_identifiers(self):
        for mode, term, uid in [('nick', 'Alice', 'u1'), ('remark', '室友', 'u1'),
                                ('qq', '123', 'u1'), ('group-name', '读书会', '321'),
                                ('group-id', '321', '321')]:
            with self.subTest(mode=mode):
                self.assertEqual(query.resolve(self.client, term, mode)[1]['peerUid'], uid)

    def test_ambiguous_and_partial_do_not_open_chat(self):
        self.client.directory.side_effect = lambda _: [self.friend, dict(self.friend, uin="456")]
        for term in ['Alice', 'Ali']:
            self.assertEqual(query.recent(self.client, term, 'nick', 5)['status'], 'choose')
        self.client.call.assert_not_called()

    def test_wrong_peer(self):
        self.client.call.return_value = {'messages': [dict(peerUid='other', chatType=1, msgTime=1, msgSeq=1)]}
        with self.assertRaisesRegex(ValueError, '会话'):
            query.recent(self.client, '123', 'qq', 1)

    def test_metadata(self):
        self.assertEqual(sessions.sessions(self.client, 'Ａｌｉ', 'friend', 1)['count'], 1)
        self.client.call.assert_not_called()
        self.client.call.return_value = {'contacts': [
            dict(chatType=1, peerUid='u1', lastMsgTime=2),
            dict(chatType=2, peerUid='321', lastMsgTime=3)]}
        self.assertEqual(sessions.sessions(self.client, '', 'any', 1)['sessions'][0]['number'], '321')

    def test_consent_at_cli(self):
        for script, args in [('query.py', ['123']), ('query.py', ['123','--all','--user-consent','recent']),
                             ('sessions.py', ['--list','--user-consent','search'])]:
            proc = subprocess.run([sys.executable, '-X', 'utf8', str(SCRIPTS / script), *args],
                                  capture_output=True)
            self.assertEqual(proc.returncode, 2)

    def test_recovery_and_incomplete_cleanup(self):
        rows = [dict(msgId=str(i), msgTime=1600000000+i, peerUid='321', chatType=2)
                for i in reversed(range(141))]
        def fetch(path, body):
            self.assertEqual(path, 'messages/fetch')
            batch = [r for r in rows if r['msgTime']*1000 <= body['filter']['endTime']]
            return {'messages': batch[:100], 'totalCount': len(batch)}
        self.client.call.side_effect = fetch
        with tempfile.TemporaryDirectory() as temp:
            peer = {'chatType': 2, 'peerUid': '321'}
            with self.assertRaises(ValueError):
                query.recover_history(self.client, peer, Path(temp), 142)
            self.assertEqual(list(Path(temp).iterdir()), [])
            result = query.recover_history(self.client, peer, Path(temp), 141)
            self.assertEqual(len(Path(result['files'][0]).read_text().splitlines()), 141)


if __name__ == '__main__':
    unittest.main()

// strings.js: the co-op screens' player-facing lines (the title's friends panel, the lobby's squad list, the teammates
// HUD, spectating, the room's messages). C(key, ...args) formats like the game's S() and falls back to it, so the
// squad lines the Roblox game already had (Downed.*, Spectate.*, Revive.*, Airlock.*) are used as they are.

import { S } from '../strings.js';

const COOP_STRINGS = {
  'Title.PlaySolo': 'PLAY SOLO',
  'Title.PlayFriends': 'PLAY WITH FRIENDS',
  'Coop.Title': 'PLAY WITH FRIENDS',
  'Coop.Intro': 'Up to four survivors. One of you hosts and shares the room code; the others join with it.',
  'Coop.Name': 'Your name',
  'Coop.Host': 'HOST A GAME',
  'Coop.Join': 'JOIN',
  'Coop.CodePlaceholder': 'ROOM CODE',
  'Coop.Back': 'BACK',
  'Coop.Enter': 'ENTER THE LOBBY',
  'Coop.Connecting': 'Connecting...',
  'Coop.Hosting': 'Opening a room...',
  'Coop.Joining': 'Looking for room %s...',
  'Coop.Unreachable': "Multiplayer can't connect on this network — single-player still works.",
  'Coop.NoHost': 'Nobody is hosting room %s. Check the code with your friend.',
  'Coop.Full': 'Room %s already has four survivors.',
  'Coop.Version': 'Room %s is running a different version of the game. Reload the page to update.',
  'Coop.BadCode': 'A room code is 5 letters and numbers.',
  'Coop.Failed': 'Could not open a room: %s',
  'Coop.RoomCode': 'ROOM CODE',
  'Coop.Copy': 'COPY',
  'Coop.Copied': 'COPIED',
  'Coop.ShareHint': 'Friends join with this code from PLAY WITH FRIENDS.',
  'Coop.HostLeft': 'The host left. The run is over.',
  'Coop.ConnectionLost': 'The connection to the room was lost.',
  'Coop.Leave': 'Leave the room',
  'Coop.LeaveRun': 'Leave the run',
  'Coop.Joined': '%s joined the room.',
  'Coop.Left': '%s left.',
  'Coop.LeftRun': '%s left the run. What they carried is where they stood.',
  'Coop.Direct': 'Direct',
  'Coop.Relay': 'Relay',
  'Coop.Linking': 'Linking',
  'Coop.Ping': '%d ms',
  'Coop.HostTag': 'HOST',
  'Coop.You': '%s (you)',
  'Coop.Votes': '%d vote(s)',
  'Coop.VoteBy': 'Squad vote: %s',
  'Coop.Squad': 'SQUAD',
  'Coop.Status.Alive': 'ALIVE',
  'Coop.Status.Downed': 'DOWN',
  'Coop.Status.Dead': 'DEAD',
  'Coop.Status.Spectating': 'WATCHING',
  'Coop.Status.Airlock': 'IN THE STAIRWELL',
  'Coop.Status.Lobby': 'IN THE LOBBY',
  'Coop.Status.Escaped': 'ESCAPED',
  'Coop.LateJoin': 'A run is underway. You will join the squad at the next stairwell.',
  'Coop.Respawned': 'Back on your feet. Keep up with the squad.',
  'Coop.SpectateHint': '%s / %s to switch',
  'Coop.ReviveHold': 'Revive',
  'Coop.ReviveObject': '%s',
  'Coop.Dropped': '%s dropped what they carried.',
  'Coop.ItemTaken': 'Someone already took that.',
  'Coop.RoomOpen': 'Room %s is open. Share the code.',
  'Coop.InRoom': 'ROOM %s',
};

/** Formats a co-op string (%d, %s, %%), falling back to the game's strings. */
export function C(key, ...args) {
  const template = COOP_STRINGS[key];
  if (template === undefined) return S(key, ...args);
  let i = 0;
  return template.replace(/%(%|d|s)/g, (m) => {
    if (m === '%%') return '%';
    const v = args[i++];
    return m === '%d' ? String(Math.trunc(Number(v) || 0)) : String(v);
  });
}

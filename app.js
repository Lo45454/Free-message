const SUPABASE_URL = "https://usccligjsnchpjtebaad.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_BmefP371TWJ8QxjSmyargQ_BKiGz1FM";

const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

let currentUser = null;
let activeContact = null;
let activeConversationId = null;
let messagesSubscription = null;
let callChannel = null;
let peerConnection = null;
let localStream = null;
let recording = null;
let audioChunks = [];

const $ = id => document.getElementById(id);

function showScreen(id) {
  document.querySelectorAll(".screen").forEach(s => s.classList.remove("active"));
  $(id).classList.add("active");
}

function initials(name) {
  return name.trim().split(/\s+/).map(w => w[0]).join("").slice(0, 2).toUpperCase();
}

function timeAgo(date) {
  return new Date(date).toLocaleTimeString("fr-CA", { hour: "2-digit", minute: "2-digit" });
}

async function signUp() {
  const username = $("username").value.trim().toLowerCase();
  const password = $("password").value;
  $("auth-error").textContent = "";

  if (!/^[a-z0-9_.]{3,20}$/.test(username)) {
    $("auth-error").textContent = "Identifiant : 3 à 20 caractères (lettres, chiffres, _ ou .).";
    return;
  }
  if (password.length < 6) {
    $("auth-error").textContent = "Le mot de passe doit avoir au moins 6 caractères.";
    return;
  }

  const email = `${username}@nova-messages.app`;
  const { data, error } = await supabase.auth.signUp({ email, password });

  if (error) {
    $("auth-error").textContent = error.message;
    return;
  }

  await supabase.from("profiles").insert({
    id: data.user.id,
    username,
    display_name: username
  });

  await loadApp();
}

async function signIn() {
  const username = $("username").value.trim().toLowerCase();
  const password = $("password").value;
  $("auth-error").textContent = "";

  const email = `${username}@nova-messages.app`;
  const { error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    $("auth-error").textContent = "Identifiant ou mot de passe incorrect.";
    return;
  }

  await loadApp();
}

async function loadApp() {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return showScreen("auth-screen");

  const { data: profile } = await supabase
    .from("profiles")
    .select("*")
    .eq("id", user.id)
    .single();

  currentUser = profile;
  $("current-user").textContent = "@" + profile.username;
  showScreen("app-screen");
  loadContacts();
  subscribeToMessages();
}

async function loadContacts(query = "") {
  let request = supabase
    .from("profiles")
    .select("id, username, display_name")
    .neq("id", currentUser.id)
    .order("username");

  if (query) request = request.ilike("username", `%${query}%`);

  const { data: users } = await request;
  const list = $("contact-list");
  list.innerHTML = "";

  users.forEach(user => {
    const div = document.createElement("div");
    div.className = "contact";
    div.innerHTML = `
      <div class="avatar">${initials(user.display_name)}</div>
      <div>
        <div class="contact-name">${user.display_name}</div>
        <div class="contact-username">@${user.username}</div>
      </div>`;
    div.onclick = () => openConversation(user);
    list.appendChild(div);
  });
}

async function openConversation(contact) {
  activeContact = contact;

  const { data: conversationId, error } = await supabase
    .rpc("get_or_create_conversation", { other_user: contact.id });

  if (error) return alert(error.message);

  activeConversationId = conversationId;
  $("empty-chat").classList.add("hidden");
  $("chat-view").classList.remove("hidden");
  $("chat-name").textContent = contact.display_name;
  $("chat-status").textContent = "@" + contact.username;

  document.querySelectorAll(".contact").forEach(c => c.classList.remove("active"));

  await loadMessages();
  subscribeToConversation();
}

async function loadMessages() {
  const { data: messages } = await supabase
    .from("messages")
    .select("*")
    .eq("conversation_id", activeConversationId)
    .order("created_at");

  renderMessages(messages || []);
}

function renderMessages(messages) {
  const box = $("messages");
  box.innerHTML = "";

  messages.forEach(message => {
    const div = document.createElement("div");
    div.className = "message" + (message.sender_id === currentUser.id ? " mine" : "");

    if (message.kind === "text") {
      div.textContent = message.content;
    } else {
      const audio = document.createElement("audio");
      audio.controls = true;
      audio.src = message.audio_url;
      div.appendChild(audio);
    }

    const time = document.createElement("span");
    time.className = "time";
    time.textContent = timeAgo(message.created_at);
    div.appendChild(time);
    box.appendChild(div);
  });

  box.scrollTop = box.scrollHeight;
}

function subscribeToConversation() {
  if (messagesSubscription) supabase.removeChannel(messagesSubscription);

  messagesSubscription = supabase
    .channel(`conversation-${activeConversationId}`)
    .on("postgres_changes", {
      event: "INSERT",
      schema: "public",
      table: "messages",
      filter: `conversation_id=eq.${activeConversationId}`
    }, payload => {
      const box = $("messages");
      const message = payload.new;
      const div = document.createElement("div");
      div.className = "message" + (message.sender_id === currentUser.id ? " mine" : "");

      if (message.kind === "text") div.textContent = message.content;
      else {
        const audio = document.createElement("audio");
        audio.controls = true;
        audio.src = message.audio_url;
        div.appendChild(audio);
      }

      const time = document.createElement("span");
      time.className = "time";
      time.textContent = timeAgo(message.created_at);
      div.appendChild(time);
      box.appendChild(div);
      box.scrollTop = box.scrollHeight;
    })
    .subscribe();
}

function subscribeToMessages() {
  supabase.channel("global-messages")
    .on("postgres_changes", {
      event: "INSERT",
      schema: "public",
      table: "messages"
    }, () => {})
    .subscribe();
}

async function sendText() {
  const content = $("message-input").value.trim();
  if (!content || !activeConversationId) return;

  await supabase.from("messages").insert({
    conversation_id: activeConversationId,
    sender_id: currentUser.id,
    kind: "text",
    content
  });

  $("message-input").value = "";
}

async function startRecording() {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    recording = new MediaRecorder(stream);
    audioChunks = [];

    recording.ondataavailable = event => audioChunks.push(event.data);

    recording.onstop = async () => {
      const blob = new Blob(audioChunks, { type: "audio/webm" });
      stream.getTracks().forEach(track => track.stop());
      $("recording-bar").classList.add("hidden");

      if (!activeConversationId) return;

      const fileName = `${currentUser.id}-${Date.now()}.webm`;
      const { error: uploadError } = await supabase.storage
        .from("audio")
        .upload(fileName, blob, { contentType: "audio/webm" });

      if (uploadError) return alert(uploadError.message);

      const { data } = supabase.storage.from("audio").getPublicUrl(fileName);

      await supabase.from("messages").insert({
        conversation_id: activeConversationId,
        sender_id: currentUser.id,
        kind: "audio",
        audio_url: data.publicUrl
      });
    };

    recording.start();
    $("recording-bar").classList.remove("hidden");
  } catch {
    alert("Le micro n'est pas accessible.");
  }
}

async function startCall(withVideo) {
  if (!activeContact) return;

  try {
    localStream = await navigator.mediaDevices.getUserMedia({
      audio: true,
      video: withVideo
    });
  } catch {
    return alert("Micro ou caméra non accessible.");
  }

  $("chat-view").classList.add("hidden");
  $("call-view").classList.remove("hidden");
  $("local-video").srcObject = localStream;

  peerConnection = new RTCPeerConnection({
    iceServers: [{ urls: ["stun:stun.l.google.com:19302"] }]
  });

  localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));

  peerConnection.ontrack = event => {
    $("remote-video").srcObject = event.streams[0];
  };

  peerConnection.onicecandidate = event => {
    if (event.candidate) {
      callChannel?.send({
        type: "broadcast",
        event: "ice",
        payload: { candidate: event.candidate, from: currentUser.id }
      });
    }
  };

  callChannel = supabase.channel(`call-${activeConversationId}`, {
    config: { broadcast: { self: false } }
  });

  callChannel
    .on("broadcast", { event: "offer" }, async ({ payload }) => {
      if (payload.target !== currentUser.id) return;
      await acceptIncomingCall(payload.offer, withVideo);
    })
    .on("broadcast", { event: "answer" }, async ({ payload }) => {
      if (payload.target !== currentUser.id) return;
      await peerConnection.setRemoteDescription(payload.answer);
    })
    .on("broadcast", { event: "ice" }, async ({ payload }) => {
      if (payload.from === currentUser.id) return;
      await peerConnection.addIceCandidate(payload.candidate);
    })
    .on("broadcast", { event: "end" }, endCall)
    .subscribe();

  const offer = await peerConnection.createOffer();
  await peerConnection.setLocalDescription(offer);

  callChannel.send({
    type: "broadcast",
    event: "offer",
    payload: { offer, from: currentUser.id, target: activeContact.id }
  });
}

async function acceptIncomingCall(offer, withVideo) {
  try {
    localStream = await navigator.mediaDevices.getUserMedia({
      audio: true,
      video: withVideo
    });
  } catch {
    return alert("Micro ou caméra non accessible.");
  }

  $("chat-view").classList.add("hidden");
  $("call-view").classList.remove("hidden");
  $("local-video").srcObject = localStream;

  peerConnection = new RTCPeerConnection({
    iceServers: [{ urls: ["stun:stun.l.google.com:19302"] }]
  });

  localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));

  peerConnection.ontrack = event => {
    $("remote-video").srcObject = event.streams[0];
  };

  peerConnection.onicecandidate = event => {
    if (event.candidate) {
      callChannel?.send({
        type: "broadcast",
        event: "ice",
        payload: { candidate: event.candidate, from: currentUser.id }
      });
    }
  };

  await peerConnection.setRemoteDescription(offer);
  const answer = await peerConnection.createAnswer();
  await peerConnection.setLocalDescription(answer);

  callChannel.send({
    type: "broadcast",
    event: "answer",
    payload: { answer, from: currentUser.id, target: offer.from || null }
  });
}

function endCall() {
  callChannel?.send({
    type: "broadcast",
    event: "end",
    payload: { from: currentUser.id }
  });

  peerConnection?.close();
  peerConnection = null;
  localStream?.getTracks().forEach(track => track.stop());
  localStream = null;
  $("remote-video").srcObject = null;
  $("local-video").srcObject = null;
  $("call-view").classList.add("hidden");
  $("chat-view").classList.remove("hidden");
}

$("signup-btn").onclick = signUp;
$("login-btn").onclick = signIn;
$("logout-btn").onclick = async () => {
  await supabase.auth.signOut();
  location.reload();
};
$("user-search").oninput = event => loadContacts(event.target.value.trim().toLowerCase());
$("send-btn").onclick = sendText;
$("message-input").addEventListener("keydown", event => {
  if (event.key === "Enter") sendText();
});
$("record-btn").onclick = startRecording;
$("cancel-recording").onclick = () => {
  recording?.stop();
  recording = null;
  $("recording-bar").classList.add("hidden");
};
$("audio-call-btn").onclick = () => startCall(false);
$("video-call-btn").onclick = () => startCall(true);
$("end-call-btn").onclick = endCall;

loadApp();

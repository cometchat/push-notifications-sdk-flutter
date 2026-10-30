# cometchat_voip_example

A tour of `cometchat_voip` that runs without a CometChat account.

On Android the buttons hand the package the call pushes CometChat sends, so the
ring, the lock-screen answer, the decline and the missed call are all real. Lock
the phone after ringing yourself to see the full-screen ring screen.

On iOS calls arrive through PushKit, which needs a real device, a signed build
and a push sent from CometChat. The example shows the VoIP token and the ring
readiness.

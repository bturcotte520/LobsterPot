/**
 * PushRelayClient — thin HTTP client for the LobsterPot push relay.
 */
export class PushRelayClient {
  constructor(
    private readonly relayUrl: string,
    private readonly adminToken: string,
    private readonly bundleId: string
  ) {}

  async register(
    bridgeId: string,
    apnsToken?: string,
    environment: "sandbox" | "production" = "sandbox"
  ): Promise<{ handle: string; grant: string } | null> {
    try {
      const res = await fetch(`${this.relayUrl}/api/register`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.adminToken}`
        },
        body: JSON.stringify({
          bundleId: this.bundleId,
          bridgeId,
          apnsDeviceToken: apnsToken,
          environment
        })
      });
      if (!res.ok) return null;
      const data = await res.json() as { handle: string; grant: string };
      return data;
    } catch {
      return null;
    }
  }

  async updateToken(handle: string, grant: string, apnsToken: string): Promise<boolean> {
    try {
      const res = await fetch(`${this.relayUrl}/api/registrations/${handle}/token`, {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${grant}`
        },
        body: JSON.stringify({ apnsDeviceToken: apnsToken })
      });
      return res.ok;
    } catch {
      return false;
    }
  }

  async send(
    handle: string,
    grant: string,
    opts: {
      title: string;
      body: string;
      conversationId?: string;
      badge?: number;
    }
  ): Promise<boolean> {
    try {
      const res = await fetch(`${this.relayUrl}/api/send`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          handle,
          grant,
          title: opts.title,
          body: opts.body,
          conversationId: opts.conversationId,
          badge: opts.badge
        })
      });
      return res.ok;
    } catch {
      return false;
    }
  }
}

import { z } from "zod";

export const LOBSTERPOT_PROTOCOL_VERSION = 1;

export const isoTimestampSchema = z.string().datetime({ offset: true });

export const conversationKindSchema = z.enum(["main", "subagent", "specialist", "support", "system"]);

export const messageRoleSchema = z.enum(["user", "assistant", "system", "tool"]);

export const messageStatusSchema = z.enum([
  "queued",
  "sending",
  "sent",
  "streaming",
  "final",
  "failed",
  "cancelled"
]);

export const attachmentSchema = z.object({
  id: z.string().uuid(),
  filename: z.string().min(1),
  contentType: z.string().min(1),
  byteSize: z.number().int().nonnegative(),
  url: z.string().optional().nullable(),
  createdAt: isoTimestampSchema
});

export const bridgeTokenCreatedSchema = z.object({
  id: z.string().min(1),
  token: z.string().startsWith("lobsterpot_"),
  createdAt: isoTimestampSchema
});

export const conversationSchema = z.object({
  id: z.string().uuid(),
  title: z.string().min(1),
  purpose: z.string().optional().nullable(),
  kind: conversationKindSchema,
  openclawSessionKey: z.string().optional().nullable(),
  openclawAgentId: z.string().optional().nullable(),
  pinned: z.boolean(),
  archivedAt: isoTimestampSchema.optional().nullable(),
  createdAt: isoTimestampSchema,
  updatedAt: isoTimestampSchema
});

export const messageSchema = z.object({
  id: z.string().uuid(),
  conversationId: z.string().uuid(),
  role: messageRoleSchema,
  content: z.string(),
  status: messageStatusSchema,
  attachments: z.array(attachmentSchema).default([]),
  sourceEventId: z.string().optional().nullable(),
  createdAt: isoTimestampSchema,
  updatedAt: isoTimestampSchema
});

export const pluginConnectionStatusSchema = z.object({
  connected: z.boolean(),
  status: z.enum(["waiting", "connected", "stale"]),
  instanceId: z.string().optional().nullable(),
  lastSeenAt: isoTimestampSchema.optional().nullable(),
  capabilities: z.array(z.string()).default([])
});

export const bridgeStatusSchema = z.object({
  ok: z.boolean(),
  service: z.literal("lobsterpot-bridge"),
  plugin: pluginConnectionStatusSchema,
  publicBaseUrl: z.string().url().optional(),
  now: isoTimestampSchema
});

export const pluginHelloSchema = z.object({
  type: z.literal("hello"),
  protocol: z.literal(LOBSTERPOT_PROTOCOL_VERSION),
  channel: z.literal("lobsterpot"),
  instanceId: z.string().min(1),
  token: z.string().startsWith("lobsterpot_"),
  capabilities: z.array(z.string()).default([]),
  resumeCursor: z.string().optional()
});

export const pluginHelloOkSchema = z.object({
  type: z.literal("hello.ok"),
  protocol: z.literal(LOBSTERPOT_PROTOCOL_VERSION),
  connectionId: z.string().uuid(),
  serverTime: z.number().int(),
  resumeCursor: z.string().optional().nullable()
});

export const pluginHelloErrorSchema = z.object({
  type: z.literal("hello.error"),
  code: z.enum(["invalid_protocol", "invalid_token", "invalid_payload"]),
  message: z.string()
});

export const inboundMessageSchema = z.object({
  type: z.literal("inbound.message"),
  id: z.string().min(1),
  conversationId: z.string().uuid(),
  senderId: z.string().min(1),
  text: z.string().min(1),
  createdAt: isoTimestampSchema.optional(),
  metadata: z.object({
    conversationTitle: z.string().optional(),
    conversationPurpose: z.string().optional().nullable(),
    conversationKind: conversationKindSchema.optional(),
    openclawSessionKey: z.string().optional().nullable(),
    openclawAgentId: z.string().optional().nullable(),
    attachments: z.array(attachmentSchema).optional()
  }).default({})
});

export const outboundMessageSchema = z.object({
  type: z.literal("outbound.message"),
  id: z.string().min(1),
  conversationId: z.string().uuid(),
  messageId: z.string().min(1),
  role: z.literal("assistant"),
  text: z.string(),
  status: z.enum(["streaming", "final"]),
  createdAt: isoTimestampSchema.optional()
});

export const outboundProgressSchema = z.object({
  type: z.literal("outbound.progress"),
  id: z.string().min(1),
  conversationId: z.string().uuid(),
  title: z.string().optional(),
  lines: z.array(z.string()).default([]),
  createdAt: isoTimestampSchema.optional()
});

export const outboundApprovalRequestedSchema = z.object({
  type: z.literal("outbound.approval.requested"),
  id: z.string().min(1),
  conversationId: z.string().uuid(),
  approvalId: z.string().min(1),
  title: z.string().min(1),
  body: z.string().optional(),
  actions: z.array(z.enum(["approve", "deny"])).default(["approve", "deny"]),
  expiresAt: isoTimestampSchema.optional().nullable(),
  createdAt: isoTimestampSchema.optional()
});

export const inboundApprovalRespondSchema = z.object({
  type: z.literal("inbound.approval.respond"),
  id: z.string().min(1),
  conversationId: z.string().uuid(),
  approvalId: z.string().min(1),
  decision: z.enum(["approve", "deny"]),
  reason: z.string().optional()
});

export const deliveryReceiptSchema = z.object({
  type: z.literal("delivery.receipt"),
  id: z.string().min(1),
  conversationId: z.string().uuid().optional(),
  acknowledgedEventId: z.string().min(1),
  status: z.enum(["accepted", "delivered", "failed"]),
  detail: z.string().optional()
});

export const presenceHeartbeatSchema = z.object({
  type: z.literal("presence.heartbeat"),
  id: z.string().min(1),
  sentAt: isoTimestampSchema
});

export const syncRequestSchema = z.object({
  type: z.literal("sync.request"),
  id: z.string().min(1),
  afterCursor: z.string().optional().nullable()
});

export const syncSnapshotSchema = z.object({
  type: z.literal("sync.snapshot"),
  id: z.string().min(1),
  cursor: z.string(),
  conversations: z.array(conversationSchema),
  messages: z.array(messageSchema)
});

export const bridgeToPluginEventSchema = z.discriminatedUnion("type", [
  pluginHelloOkSchema,
  pluginHelloErrorSchema,
  inboundMessageSchema,
  inboundApprovalRespondSchema,
  deliveryReceiptSchema,
  presenceHeartbeatSchema,
  syncSnapshotSchema
]);

export const pluginToBridgeEventSchema = z.discriminatedUnion("type", [
  pluginHelloSchema,
  outboundMessageSchema,
  outboundProgressSchema,
  outboundApprovalRequestedSchema,
  deliveryReceiptSchema,
  presenceHeartbeatSchema,
  syncRequestSchema
]);

export const publicBridgeEventSchema = z.object({
  id: z.string().uuid(),
  cursor: z.string(),
  type: z.string().min(1),
  conversationId: z.string().uuid().optional().nullable(),
  payload: z.unknown(),
  createdAt: isoTimestampSchema
});

export type BridgeTokenCreated = z.infer<typeof bridgeTokenCreatedSchema>;
export type Conversation = z.infer<typeof conversationSchema>;
export type Attachment = z.infer<typeof attachmentSchema>;
export type Message = z.infer<typeof messageSchema>;
export type PluginConnectionStatus = z.infer<typeof pluginConnectionStatusSchema>;
export type BridgeStatus = z.infer<typeof bridgeStatusSchema>;
export type PluginHello = z.infer<typeof pluginHelloSchema>;
export type PluginHelloOk = z.infer<typeof pluginHelloOkSchema>;
export type BridgeToPluginEvent = z.infer<typeof bridgeToPluginEventSchema>;
export type PluginToBridgeEvent = z.infer<typeof pluginToBridgeEventSchema>;
export type InboundMessage = z.infer<typeof inboundMessageSchema>;
export type OutboundMessage = z.infer<typeof outboundMessageSchema>;
export type PublicBridgeEvent = z.infer<typeof publicBridgeEventSchema>;

export function parsePluginEvent(input: unknown): PluginToBridgeEvent {
  return pluginToBridgeEventSchema.parse(input);
}

export function parseBridgeEvent(input: unknown): BridgeToPluginEvent {
  return bridgeToPluginEventSchema.parse(input);
}

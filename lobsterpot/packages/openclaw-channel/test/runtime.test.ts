import { describe, expect, it } from "vitest";
import {
  buildBodyForAgent,
  extractRequestedSubagentLabel,
  extractSpecialistAnnouncement,
  extractSubagentAnnounceText,
  extractSubagentPurpose
} from "../src/runtime.js";

describe("runtime specialist helpers", () => {
  it("extracts quoted subagent labels", () => {
    expect(extractRequestedSubagentLabel('Spawn a subagent. Label it "Spanish Tutor".')).toBe("Spanish Tutor");
    expect(extractRequestedSubagentLabel('Spawn a subagent named "Research Lead".')).toBe("Research Lead");
    expect(extractRequestedSubagentLabel("Create a subagent for German tutoring.")).toBe("German Tutor");
    expect(extractRequestedSubagentLabel("Set up a Spanish tutor to help me practice.")).toBe("Spanish Tutor");
  });

  it("extracts subagent purpose from spawn prompts", () => {
    expect(extractSubagentPurpose("The subagent's job is to help me practice beginner Spanish."))
      .toBe("help me practice beginner Spanish.");
  });

  it("extracts child announce text from main-agent replies", () => {
    const reply = "Spanish Tutor is ready. Here's what it sent:\n- Hola, I can help you practice.";
    expect(extractSubagentAnnounceText(reply, "Spanish Tutor")).toBe("Hola, I can help you practice.");
  });

  it("injects specialist context only for specialist threads or purposeful conversations", () => {
    expect(buildBodyForAgent({ text: "Hola", kind: "main" })).toBeUndefined();

    expect(buildBodyForAgent({
      text: "Hola",
      title: "Spanish Tutor",
      purpose: "Practice beginner Spanish.",
      kind: "specialist"
    })).toContain('You are the persistent specialist conversation named "Spanish Tutor".');

    expect(buildBodyForAgent({
      text: "Hola",
      title: "Spanish Tutor",
      purpose: "Practice beginner Spanish.",
      kind: "subagent"
    })).toContain('You are the persistent subagent conversation named "Spanish Tutor".');
  });

  it("extracts specialist announcement from main-agent ready messages", () => {
    const msg = "Chinese Tutor is ready! Here's its intro:\n\n---\n\nHello! I am your tutor.\n\n---\n\nPick a topic!";
    const ann = extractSpecialistAnnouncement(msg);
    expect(ann?.label).toBe("Chinese Tutor");
    expect(ann?.body).toContain("Hello! I am your tutor.");
  });

  it("extracts specialist announcement from spawned phrasing", () => {
    const msg = "German Tutor subagent spawned! 🇩🇪 Its intro will arrive shortly.";
    const ann = extractSpecialistAnnouncement(msg);
    expect(ann?.label).toBe("German Tutor");
  });
});

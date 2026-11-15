import React from "react";
import { Composition } from "remotion";
import { Pitwall, TOTAL } from "./Pitwall";

export const Root: React.FC = () => (
  <Composition id="Pitwall" component={Pitwall} durationInFrames={TOTAL} fps={30} width={1920} height={1080} />
);

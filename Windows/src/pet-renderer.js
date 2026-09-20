/* WebGL2 translation of Source/Renderer.swift's inverse-mapping Metal shader.
 * Eight textures, same 154-float layout, premultiplied alpha, original RGBA8 maps. */
(function (root) {
  const vertex = `#version 300 es
in vec2 position; in vec2 source; out vec2 canvasPoint;
void main(){gl_Position=vec4(position,0.,1.);canvasPoint=source;}`;
  const fragment = `#version 300 es
precision highp float;
uniform float P[154];
uniform sampler2D base, overlay, mouth, m0,m1,m2,m3,m4;
in vec2 canvasPoint; out vec4 result;
vec4 zeroSample(sampler2D tex,vec2 uv){if(any(lessThan(uv,vec2(0.)))||any(greaterThan(uv,vec2(1.))))return vec4(0.);return texture(tex,uv);}
float channel(int c,vec4 m[5]){if(c<0)return 0.;return m[c/4][c%4];}
void main(){
 vec2 canvas=vec2(P[0],P[1]);
 vec2 q=canvasPoint-vec2(P[10],P[11]);
 vec2 pivot=vec2(P[5],P[6]);
 float ca=cos(-P[7]),sa=sin(-P[7]);vec2 r=q-pivot;
 q=pivot+vec2(ca*r.x-sa*r.y,sa*r.x+ca*r.y);
 vec2 scalePivot=vec2(P[28],P[29]);q=scalePivot+(q-scalePivot)/vec2(P[8],P[9]);
 vec2 uv=q/canvas;
 vec4 m[5]=vec4[5](zeroSample(m0,uv),zeroSample(m1,uv),zeroSample(m2,uv),zeroSample(m3,uv),zeroSample(m4,uv));
 vec2 d=vec2(0.);
 for(int i=0;i<6;i++){
  int o=32+i*13;float w=channel(int(P[o+2]),m);if(w<.0005)continue;
  float angle=P[o+4];int alongChannel=int(P[o+3]);
  if(alongChannel>=0){float a=clamp(channel(alongChannel,m),0.,1.)*8.;int k=min(int(a),7);angle=mix(P[o+4+k],P[o+5+k],a-float(k));}
  float th=-angle*w;vec2 rr=q-vec2(P[o],P[o+1]);float c=cos(th),s=sin(th);
  d+=vec2((c-1.)*rr.x-s*rr.y,s*rr.x+(c-1.)*rr.y);
 }
 for(int i=0;i<8;i++){int o=110+i*3;float w=channel(int(P[o]),m);d+=w*vec2(P[o+1],P[o+2]);}
 for(int i=0;i<4;i++){int o=134+i*5;float w=channel(int(P[o]),m);if(w<.0005)continue;vec2 k=vec2(P[o+3],P[o+4]);d-=(q-vec2(P[o+1],P[o+2]))*(1.-1./k)*w;}
 vec2 s=q+d,suv=s/canvas;
 vec4 n[5]=vec4[5](zeroSample(m0,suv),zeroSample(m1,suv),zeroSample(m2,suv),zeroSample(m3,suv),zeroSample(m4,suv));
 float pad=P[2],lid=s.x<P[16]?P[14]:P[15];
 float squeeze=clamp((s.y-lid)*P[13],-P[26],P[26])*n[3].r;
 vec4 color=zeroSample(base,(s+vec2(0.,squeeze)-pad)/vec2(P[3],P[4]));
 float swapAmount=P[17]*n[3].g;
 if(swapAmount>0.)color=mix(color,zeroSample(overlay,(s-pad)/vec2(P[24],P[25])),swapAmount);
 float open=P[18];if(open>0.){float mask=channel(int(P[19]),n),edge=open*1.15;float shown=mask*(1.-smoothstep(edge-.15,edge,n[3].a));vec2 offset=vec2(P[20],P[21]);color=mix(color,zeroSample(mouth,(s-pad-offset)/vec2(P[22],P[23])),shown);}
 result=color*P[12];
}`;
  class RigRenderer {
    constructor(data) {
      this.data = data;
      this.canvas = document.createElement("canvas");
      this.canvas.width = 840;
      this.canvas.height = 520;
      const gl = (this.gl = this.canvas.getContext("webgl2", {
        alpha: true,
        premultipliedAlpha: true,
        preserveDrawingBuffer: true,
        antialias: false,
      }));
      if (!gl) throw new Error("WebGL2 动画不可用");
      const shader = (kind, src) => {
        const s = gl.createShader(kind);
        gl.shaderSource(s, src);
        gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS))
          throw new Error(gl.getShaderInfoLog(s));
        return s;
      };
      this.program = gl.createProgram();
      gl.attachShader(this.program, shader(gl.VERTEX_SHADER, vertex));
      gl.attachShader(this.program, shader(gl.FRAGMENT_SHADER, fragment));
      gl.linkProgram(this.program);
      if (!gl.getProgramParameter(this.program, gl.LINK_STATUS))
        throw new Error(gl.getProgramInfoLog(this.program));
      gl.useProgram(this.program);
      this.params = gl.getUniformLocation(this.program, "P[0]");
      this.buffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
      for (const [name, offset] of [
        ["position", 0],
        ["source", 8],
      ]) {
        const a = gl.getAttribLocation(this.program, name);
        gl.enableVertexAttribArray(a);
        gl.vertexAttribPointer(a, 2, gl.FLOAT, false, 16, offset);
      }
      ["base", "overlay", "mouth", "m0", "m1", "m2", "m3", "m4"].forEach(
        (s, i) => gl.uniform1i(gl.getUniformLocation(this.program, s), i),
      );
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
      this.textures = {};
    }
    texture(w, h, bytes, art = false) {
      const g = this.gl,
        t = g.createTexture();
      g.bindTexture(g.TEXTURE_2D, t);
      g.pixelStorei(g.UNPACK_PREMULTIPLY_ALPHA_WEBGL, art);
      if (art)
        g.texImage2D(g.TEXTURE_2D, 0, g.RGBA, g.RGBA, g.UNSIGNED_BYTE, bytes);
      else
        g.texImage2D(
          g.TEXTURE_2D,
          0,
          g.RGBA,
          w,
          h,
          0,
          g.RGBA,
          g.UNSIGNED_BYTE,
          bytes,
        );
      g.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_S, g.CLAMP_TO_EDGE);
      g.texParameteri(g.TEXTURE_2D, g.TEXTURE_WRAP_T, g.CLAMP_TO_EDGE);
      g.texParameteri(g.TEXTURE_2D, g.TEXTURE_MAG_FILTER, g.LINEAR);
      g.texParameteri(
        g.TEXTURE_2D,
        g.TEXTURE_MIN_FILTER,
        art ? g.LINEAR_MIPMAP_LINEAR : g.LINEAR,
      );
      if (art) g.generateMipmap(g.TEXTURE_2D);
      return t;
    }
    async load(base = "../assets/rig/") {
      const art = async (name) => {
        const im = new Image();
        im.src = base + name + ".png";
        await im.decode();
        return this.texture(0, 0, im, true);
      };
      [this.blink, this.wave, this.yawn] = await Promise.all(
        ["blink", "wave", "yawn"].map(art),
      );
      this.empty = this.texture(1, 1, new Uint8Array(4));
      for (const [key, r] of Object.entries(this.data.rigs)) {
        const maps = await Promise.all(
          Array.from({ length: 5 }, async (_, i) => {
            const response = await fetch(base + key + "-map" + i + ".rgba.gz");
            if (!response.ok) throw new Error("缺少动作权重");
            const bytes = new Uint8Array(
              await new Response(
                response.body.pipeThrough(new DecompressionStream("gzip")),
              ).arrayBuffer(),
            );
            if (bytes.length !== r.width * r.height * 4)
              throw new Error("动作权重损坏");
            return this.texture(r.width, r.height, bytes);
          }),
        );
        this.textures[key] = [
          await art(key + "-base"),
          key === "idle" ? this.blink : this.empty,
          ...maps,
        ];
      }
    }
    render(
      motion,
      pose = "idle",
      { height = 140, cx = 210, ground = 247, flip = 1, opacity = 1 } = {},
    ) {
      const g = this.gl;
      g.viewport(0, 0, this.canvas.width, this.canvas.height);
      g.clearColor(0, 0, 0, 0);
      g.clear(g.COLOR_BUFFER_BIT);
      g.useProgram(this.program);
      const scale = height / this.data.sizes.idle[1],
        shift = { idle: 0, sleep: 2, wave: 4, walk: -40 }[pose] || 0;
      const layers =
        pose === "walk"
          ? [
              "walk.backFar",
              "walk.frontFar",
              "walk",
              "walk.backNear",
              "walk.frontNear",
            ]
          : [pose];
      for (const key of layers) {
        const r = this.data.rigs[key],
          textures = this.textures[key],
          p = motion.params(key, opacity);
        if (!r || !textures) continue;
        const width = r.width * scale,
          h = r.height * scale,
          center = cx + shift * scale * flip;
        const left = ((center - (width * abs(flip)) / 2) / 420) * 2 - 1,
          right = ((center + (width * abs(flip)) / 2) / 420) * 2 - 1,
          top = 1 - ((ground - (r.height - 40) * scale) / 260) * 2,
          bottom = 1 - ((ground + 40 * scale) / 260) * 2;
        const u0 = flip < 0 ? r.width : 0,
          u1 = flip < 0 ? 0 : r.width;
        g.bufferData(
          g.ARRAY_BUFFER,
          new Float32Array([
            left,
            bottom,
            u0,
            r.height,
            right,
            bottom,
            u1,
            r.height,
            left,
            top,
            u0,
            0,
            right,
            top,
            u1,
            0,
          ]),
          g.DYNAMIC_DRAW,
        );
        const ts = [
          textures[0],
          textures[1],
          p[27] > 0.5 ? this.yawn : this.wave,
          ...textures.slice(2),
        ];
        ts.forEach((t, i) => {
          g.activeTexture(g.TEXTURE0 + i);
          g.bindTexture(g.TEXTURE_2D, t);
        });
        g.uniform1fv(this.params, p);
        g.drawArrays(g.TRIANGLE_STRIP, 0, 4);
      }
      return this.canvas;
    }
  }
  const abs = Math.abs;
  root.PetRenderer = { RigRenderer, vertex, fragment };
})(globalThis);

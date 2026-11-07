#version 450

layout(location = 0) out vec4 outColor;

void main() {
    // Distinct TahoeBoot verification color: R=0.25, G=0.50, B=0.75, A=1.0
    outColor = vec4(0.25, 0.50, 0.75, 1.0);
}

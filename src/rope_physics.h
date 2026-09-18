// 接続物とロープを同じ物理エンジンで解く部品。
// 責務: 区間の質量・速度とJointを持ち、切断時には既存の物理状態を移す。
// 設計思想: 毎フレームの剛体座標上書きを避け、2Dと3Dの管理手順を共有する。
#ifndef SVG2D_ROPE_PHYSICS_H
#define SVG2D_ROPE_PHYSICS_H
#include <godot_cpp/classes/animatable_body2d.hpp>
#include <godot_cpp/classes/animatable_body3d.hpp>
#include <godot_cpp/classes/rigid_body2d.hpp>
#include <godot_cpp/classes/rigid_body3d.hpp>
#include <godot_cpp/classes/pin_joint2d.hpp>
#include <godot_cpp/classes/pin_joint3d.hpp>
#include <godot_cpp/classes/collision_shape2d.hpp>
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/capsule_shape2d.hpp>
#include <godot_cpp/classes/capsule_shape3d.hpp>
#include <godot_cpp/core/memory.hpp>
#include <algorithm>
#include <cmath>
#include <memory>
#include <vector>

namespace svg2d {
using namespace godot;
// 次元固有の姿勢・角速度・Joint生成だけを切り出す。
struct RopeSpace2D {
	using V = Vector2; using Body = RigidBody2D; using Node = Node2D;
	using Anchor = AnimatableBody2D; using Target = PhysicsBody2D;
	using Joint = PinJoint2D; using Shape = CapsuleShape2D; using Collision = CollisionShape2D;
	static void pose(Body *body, V a, V b) {
		body->set_global_position((a + b) * 0.5f);
		body->set_global_rotation((b - a).angle() - 1.5707963267948966);
	}
	static V spin(Body *body, V offset) { return V(-offset.y, offset.x) * body->get_angular_velocity(); }
	static void angular(Body *body, V edge, V velocity) {
		body->set_angular_velocity(edge.length_squared() > 1e-12 ? edge.cross(velocity) / edge.length_squared() : 0.0);
	}
	static Joint *joint(Target *a, Target *b, V position) {
		// 2Dのworld座標アンカー算出前に、初期姿勢を物理サーバーへ送る。
		a->force_update_transform(); b->force_update_transform();
		auto *joint = memnew(Joint); joint->set_name("RopeJoint");
		a->add_child(joint, false, godot::Node::INTERNAL_MODE_BACK);
		joint->set_global_position(position);
		joint->set_node_a(joint->get_path_to(a)); joint->set_node_b(joint->get_path_to(b));
		return joint;
	}
};
struct RopeSpace3D {
	using V = Vector3; using Body = RigidBody3D; using Node = Node3D;
	using Anchor = AnimatableBody3D; using Target = PhysicsBody3D;
	using Joint = PinJoint3D; using Shape = CapsuleShape3D; using Collision = CollisionShape3D;
	static void pose(Body *body, V a, V b) {
		V edge = b - a;
		Basis basis = edge.length_squared() > 1e-12 ? Basis(Quaternion(V(0, 1, 0), edge.normalized())) : Basis();
		body->set_global_transform(Transform3D(basis, (a + b) * 0.5f));
	}
	static V spin(Body *body, V offset) { return body->get_angular_velocity().cross(offset); }
	static void angular(Body *body, V edge, V velocity) {
		body->set_angular_velocity(edge.length_squared() > 1e-12 ? edge.cross(velocity) / edge.length_squared() : V());
	}
	static Joint *joint(Target *a, Target *b, V position) {
		// 2Dのworld座標アンカー算出前に、初期姿勢を物理サーバーへ送る。
		a->force_update_transform(); b->force_update_transform();
		auto *joint = memnew(Joint); joint->set_name("RopeJoint");
		a->add_child(joint, false, godot::Node::INTERNAL_MODE_BACK);
		joint->set_global_position(position);
		joint->set_node_a(joint->get_path_to(a)); joint->set_node_b(joint->get_path_to(b));
		return joint;
	}
};

template <typename Space>
struct RopePhysics {
	using V = typename Space::V; using Body = typename Space::Body;
	using Node = typename Space::Node; using Target = typename Space::Target;
	struct Segment { Body *body; V a, b; }; // 剛体内の区間端点
	std::vector<Segment> segments;
	using Joint = typename Space::Joint;
	std::vector<Joint *> links;
	typename Space::Anchor *anchor = nullptr;
	Joint *pin = nullptr, *attachment = nullptr;
	uint64_t target_id = 0;
	int target_point = -1;
	double last_mass = -1, last_rate = -1;
	V last_gravity;
	bool running = true;

	// Joint自身が剛体のtree離脱を監視する。所有ノードの破棄に解放を任せる。
	static void release(Joint *&joint) {
		if (!joint) return;
		joint->set_node_a(NodePath()); joint->set_node_b(NodePath()); joint->queue_free(); joint = nullptr;
	}
	void clear_joints() {
		release(pin); release(attachment);
		for (auto *&joint : links) release(joint);
		links.clear();
	}
	// 作り直しでは拘束を先に消し、解放待ちの剛体を動かさない。
	void clear_nodes() {
		clear_joints();
		for (auto &segment : segments) { segment.body->set_freeze_enabled(true); segment.body->queue_free(); }
		segments.clear();
		if (anchor) { anchor->queue_free(); anchor = nullptr; }
	}
	// 初回だけ区間剛体を生成し、以後の位置・回転はGodotに任せる。
	void build(Node *owner, const std::vector<V> &points, const std::vector<V> &previous,
			double dt, bool pinned, double mass) {
		for (size_t i = 0; i + 1 < points.size(); i++) {
			V a = owner->to_global(points[i]), b = owner->to_global(points[i + 1]);
			auto *body = memnew(Body);
			body->set_name("RopeSegment"); body->set_as_top_level(true);
			body->set_collision_layer(0); body->set_collision_mask(0);
			body->set_gravity_scale(0); body->set_mass(mass / (points.size() - 1));
			body->set_linear_damp_mode(Body::DAMP_MODE_REPLACE);
			body->set_angular_damp_mode(Body::DAMP_MODE_REPLACE);
			auto *collision = memnew(typename Space::Collision);
			Ref<typename Space::Shape> shape; shape.instantiate();
			double length = std::max(0.0001, (double)a.distance_to(b));
			shape->set_radius(length * 0.025); shape->set_height(length);
			collision->set_shape(shape); body->add_child(collision, false, godot::Node::INTERNAL_MODE_BACK);
			owner->add_child(body, false, godot::Node::INTERNAL_MODE_BACK);
			Space::pose(body, a, b);
			V va = (a - owner->to_global(previous[i])) / dt;
			V vb = (b - owner->to_global(previous[i + 1])) / dt;
			body->set_linear_velocity((va + vb) * 0.5f); Space::angular(body, b - a, vb - va);
			segments.push_back({body, body->to_local(a), body->to_local(b)});
		}
		if (pinned) {
			anchor = memnew(typename Space::Anchor); anchor->set_name("RopeStart");
			anchor->set_collision_layer(0); anchor->set_collision_mask(0);
			anchor->set_position(points.front()); owner->add_child(anchor, false, godot::Node::INTERNAL_MODE_BACK);
		}
	}
	// 接続先が替わるときだけJointを作り、現在の接点を剛体内へ記録する。
	void connect(Node *owner, Target *target, int point, const std::vector<V> &points) {
		uint64_t id = target ? target->get_instance_id() : 0;
		if (links.empty()) {
			for (size_t i = 1; i < segments.size(); i++)
				links.push_back(Space::joint(segments[i - 1].body, segments[i].body,
						segments[i - 1].body->to_global(segments[i - 1].b)));
		}
		if (anchor && !pin) pin = Space::joint(anchor, segments.front().body, anchor->get_global_position());
		if (id == target_id && point == target_point && (!id || attachment)) return;
		release(attachment); target_id = id; target_point = point;
		if (target) attachment = Space::joint(segments[std::min(point, (int)segments.size() - 1)].body,
				target, owner->to_global(points[(size_t)point]));
	}
	// 描画座標とVerletへ戻せる速度を、剛体端点から取り出す。
	void read(Node *owner, std::vector<V> &points, std::vector<V> &previous, double dt) const {
		for (size_t i = 0; i < points.size(); i++) {
			const auto &segment = segments[std::min(i, segments.size() - 1)];
			V position = segment.body->to_global(i < segments.size() ? segment.a : segment.b);
			V velocity = segment.body->get_linear_velocity() + Space::spin(segment.body, position - segment.body->get_global_position());
			points[i] = owner->to_local(position); previous[i] = owner->to_local(position - velocity * dt);
		}
	}
	// 変化した設定だけ物理サーバーへ送る。停止時も剛体と表示を揃える。
	void configure(double mass, double damping, V gravity, bool enabled, double dt) {
		double rate = (1.0 - std::pow(1.0 - damping, dt * 60.0)) / dt;
		bool changed = mass != last_mass || rate != last_rate || gravity != last_gravity;
		if (!changed && running == enabled) return;
		for (auto &segment : segments) {
			if (changed) {
				segment.body->set_mass(mass / segments.size());
				segment.body->set_constant_force(gravity * (mass / segments.size()));
				segment.body->set_linear_damp(rate); segment.body->set_angular_damp(rate);
				segment.body->set_sleeping(false);
			}
			if (running != enabled) segment.body->set_freeze_enabled(!enabled);
		}
		last_mass = mass; last_rate = rate; last_gravity = gravity; running = enabled;
	}
	// Jointを解除してから区間剛体を移し、移動完了後に残る接点だけ再接続する。
	std::unique_ptr<RopePhysics> split(size_t point, Node *owner) {
		auto tail = std::make_unique<RopePhysics>();
		clear_joints();
		tail->segments.assign(segments.begin() + point, segments.end()); segments.resize(point);
		for (auto &segment : tail->segments) {
			auto transform = segment.body->get_global_transform();
			auto velocity = segment.body->get_linear_velocity();
			auto angular = segment.body->get_angular_velocity();
			segment.body->get_parent()->remove_child(segment.body);
			owner->add_child(segment.body, false, godot::Node::INTERNAL_MODE_BACK);
			segment.body->set_global_transform(transform);
			segment.body->set_linear_velocity(velocity); segment.body->set_angular_velocity(angular);
		}
		if (target_point >= (int)point) {
			tail->target_id = target_id; tail->target_point = target_point - (int)point;
			target_id = 0; target_point = -1;
		}
		tail->running = running; last_mass = -1;
		return tail;
	}
};
using RopePhysics2D = RopePhysics<RopeSpace2D>;
using RopePhysics3D = RopePhysics<RopeSpace3D>;
} // namespace svg2d
#endif

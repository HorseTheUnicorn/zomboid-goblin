package com.horsetheunicorn.goblinsurvivor;

import java.util.*;
import java.util.function.BiPredicate;

/** Bounded cardinal A*: collision policy belongs to the world adapter. */
public final class GridRoute {
    public record Cell(int x, int y) { }
    private record Node(Cell cell, double cost, double score) { }
    private GridRoute() { }

    public static List<Cell> find(Cell start, Cell goal, double stopRadius, int budget,
            BiPredicate<Cell, Cell> canStep) {
        if (budget <= 0 || !Double.isFinite(stopRadius) || stopRadius < 0) return List.of();
        PriorityQueue<Node> open = new PriorityQueue<>(Comparator.comparingDouble(Node::score));
        Map<Cell, Double> cost = new HashMap<>();
        Map<Cell, Cell> parent = new HashMap<>();
        cost.put(start, 0.0);
        open.add(new Node(start, 0, distance(start, goal)));
        int expanded = 0;
        while (!open.isEmpty() && expanded < budget) {
            Node node = open.remove();
            if (node.cost() != cost.getOrDefault(node.cell(), Double.POSITIVE_INFINITY)) continue;
            expanded++;
            Cell here = node.cell();
            if (distance(here, goal) <= stopRadius) {
                LinkedList<Cell> path = new LinkedList<>();
                while (!here.equals(start)) {
                    path.addFirst(here);
                    here = parent.get(here);
                }
                return List.copyOf(path);
            }
            for (int[] d : new int[][] {{1,0},{0,1},{-1,0},{0,-1}}) {
                Cell next = new Cell(here.x() + d[0], here.y() + d[1]);
                if (!canStep.test(here, next)) continue;
                double nextCost = node.cost() + 1;
                if (nextCost >= cost.getOrDefault(next, Double.POSITIVE_INFINITY)) continue;
                cost.put(next, nextCost);
                parent.put(next, here);
                open.add(new Node(next, nextCost, nextCost + Math.max(0, distance(next, goal) - stopRadius)));
            }
        }
        return List.of();
    }

    private static double distance(Cell a, Cell b) {
        return Math.hypot((double)a.x() - b.x(), (double)a.y() - b.y());
    }
}
